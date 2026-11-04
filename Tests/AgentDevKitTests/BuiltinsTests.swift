import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import Foundation
import Testing

/// A minimal app: a home screen and a detail screen whose item loads asynchronously.
@MainActor
final class ToyApp: AgentAdapter {
    struct Destination {
        let screen: String
        let item: String?
    }

    struct SaveInput: Decodable {
        let name: String
    }

    static let fixtures = ["two-items-v1": ["a", "b"], "empty-v1": [String]()]

    let runtime: AgentRuntime
    private(set) var screen = "home"
    private(set) var item: String?
    private(set) var presentation = UUID()
    private(set) var loading = false
    private(set) var failed = false
    var failNextLoad = false
    var loadDelay: Duration = .milliseconds(40)
    private var items: [String] = []
    private var savedName: String?

    init(runtime: AgentRuntime) { self.runtime = runtime }

    var currentPresentation: UUID? { presentation }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        var fields: [String: JSONValue] = ["itemCount": .integer(Int64(items.count))]
        if let item { fields["item"] = .string(item) }
        if let savedName { fields["savedName"] = .string(savedName) }
        return ScreenSnapshot(screenId: screen, windowId: "main", ready: !loading && !failed, fields: fields,
                              operationId: screen == "detail" ? presentation : nil,
                              blockers: loading ? ["item.load"] : failed ? ["item.failed"] : [])
    }

    func resolve(route: String, context: RouteContext, fixture: String?) throws -> Destination {
        let available = fixture.map { Self.fixtures[$0] ?? [] } ?? items
        guard route == "detail" else { return Destination(screen: route, item: nil) }
        guard let item = context["item"]?.stringValue, available.contains(item) else {
            throw Failure(.invalidParams, "Select an existing item.", details: ["field": "context.item"])
        }
        return Destination(screen: route, item: item)
    }

    func present(_ destination: Destination, request: PresentationRequest) -> UUID {
        runtime.end("load", outcome: .cancelled)
        presentation = UUID()
        screen = destination.screen
        item = destination.item
        failed = false
        runtime.begin("screen", .screen, name: destination.screen, scope: destination.screen,
                      parentId: request.scenarioId, correlationId: request.requestId)
        if destination.screen == "detail" {
            loading = true
            let current = presentation
            runtime.begin("load", .work, name: "item.load", scope: "detail", id: current, parentId: request.scenarioId)
            Task {
                try? await Task.sleep(for: loadDelay)
                finishLoad(current)
            }
        } else {
            loading = false
        }
        return presentation
    }

    private func finishLoad(_ id: UUID) {
        guard id == presentation, loading else { return }
        loading = false
        if failNextLoad {
            failNextLoad = false
            failed = true
            runtime.end("load", outcome: .failed)
            runtime.diagnose(DiagnosticRecord(severity: .error, category: "items", code: "ITEM_LOAD_FAILED",
                                              message: "The item could not be loaded."))
        } else {
            runtime.end("load", outcome: .completed)
        }
    }

    func readiness(of presentation: UUID) -> Readiness {
        guard presentation == self.presentation else { return .superseded }
        if failed { return .failed(Failure(.notReady, "Item loading failed.", details: ["blockers": ["item.failed"]])) }
        return loading ? .pending(blockers: ["item.load"]) : .ready
    }

    func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue] {
        items = Self.fixtures[id] ?? []
        screen = "home"
        item = nil
        runtime.record("fixture.loaded", scope: "app", correlationId: context.requestId, changedFields: ["itemCount"])
        return ["itemCount": .integer(Int64(items.count))]
    }

    func save(_ name: String) {
        savedName = name
        runtime.record("item.saved", scope: "detail", changedFields: ["savedName"])
    }

    var catalog: AgentCatalog {
        AgentCatalog(
            scopes: ["current-screen", "app"],
            routes: [
                AgentRoute("home"),
                AgentRoute("detail", context: ObjectSchema(["item": .string(maxLength: 32)], required: ["item"]),
                           windowId: "main", readinessGates: ["item.load"])
            ],
            fixtures: Array(Self.fixtures.keys).sorted(),
            actions: [
                AgentAction("detail.save", scope: "detail", input: ObjectSchema(["name": .string(maxLength: 16)], required: ["name"]),
                            as: SaveInput.self, enabled: { [unowned self] in screen == "detail" && !loading }) { [unowned self] input, _ in
                    save(input.name)
                    return .completed
                }
            ],
            conditions: [
                AgentCondition("items.present") { [unowned self] _, _ in
                    items.isEmpty ? .pending(blockers: ["items.empty"]) : .satisfied
                }
            ],
            lifecycle: [.init(kind: .screen, name: "home"), .init(kind: .screen, name: "detail"), .init(kind: .work, name: "item.load")],
            diagnosticCategories: ["items"]
        )
    }
}

struct ToyHost {
    let host: AgentHost
    let app: ToyApp
    let client: AgentClient

    @MainActor
    static func start(allowMutations: Bool = true) async throws -> ToyHost {
        let runtime = AgentRuntime()
        let app = ToyApp(runtime: runtime)
        let bundleId = "dev.agentdevkit.tests.toy." + UUID().uuidString
        let host = AgentHost(adapter: app, runtime: runtime, catalog: app.catalog, allowMutations: allowMutations,
                             configuration: .init(identity: .fixed(bundleId: bundleId, buildFingerprint: "toy")))
        try await host.start()
        return ToyHost(host: host, app: app, client: try AgentClient(session: bundleId))
    }

    /// Runs `body` with a live host and always awaits `stop()`.
    static func run(allowMutations: Bool = true, _ body: (ToyHost) async throws -> Void) async throws {
        let toy = try await start(allowMutations: allowMutations)
        do { try await body(toy) } catch {
            await toy.stop()
            throw error
        }
        await toy.stop()
    }

    func call<Input, Output>(_ command: Command<Input, Output>, _ input: Input, timeoutMs: Int? = nil) async throws -> Output {
        try #require(try await client.call(command, input, timeoutMs: timeoutMs).result)
    }

    func stop() async { await host.stop() }
}

private func failure(_ body: () async throws -> some Any) async -> Failure? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? Failure
    }
}

@Suite struct BuiltinsTests {
    @Test func capabilitiesComeFromTheCatalogAndHideMutationsWhenReadOnly() async throws {
        try await ToyHost.run() { mutable in
            let capabilities = try #require(try await mutable.client.capabilities().result)
            #expect(capabilities.methods.contains("scenario.prepare"))
            #expect(capabilities.routes.map(\.id) == ["home", "detail"])
            #expect(capabilities.routes[1].contextSchema.objectValue?["required"] == ["item"])
            #expect(capabilities.conditions.map(\.id).contains("items.present"))
            #expect(capabilities.lifecycle.contains(.init(kind: .scenario, name: "scenario.prepare")))
            #expect(capabilities.libraryVersion == AgentDevKitVersion.current)

            try await ToyHost.run(allowMutations: false) { readOnly in
                let limited = try #require(try await readOnly.client.capabilities().result)
                #expect(limited.readOnly)
                #expect(limited.routes.isEmpty && limited.fixtures.isEmpty && limited.actions.isEmpty)
                #expect(!limited.methods.contains("navigation.open") && !limited.methods.contains("actions.invoke"))
                #expect(limited.methods.contains("runtime.wait") && limited.methods.contains("state.observe"))
                #expect(!limited.lifecycle.contains { $0.kind == .scenario })
                #expect(try await readOnly.call(AppCommands.actions, EmptyParameters()).isEmpty)
            }
        }
    }

    @Test func scenarioLoadsFixtureOpensScreenAndWaitsForTrackedWork() async throws {
        try await ToyHost.run() { toy in
            let result = try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "two-items-v1", route: "detail", context: ["item": "b"]))
            #expect(result.screen.screenId == "detail")
            #expect(result.screen.ready)
            #expect(result.screen.fields["item"] == "b")
            #expect(result.fixture.fields["itemCount"] == 2)

            let events = try await toy.call(AppCommands.events, EventsRequest(revision: 0)).events
            let scenario = try #require(events.first { $0.type == "scenario.started" }?.lifecycle)
            let load = try #require(events.first { $0.type == "work.finished" }?.lifecycle)
            #expect(load.parentId == scenario.id)
            #expect(load.outcome == .completed)
            #expect(events.last?.type == "scenario.finished")
            #expect(result.screen.revision == events.last?.revision, "The scenario result covers its terminal event.")
        }
    }

    @Test func scenarioPreflightFailureLeavesStateUntouched() async throws {
        try await ToyHost.run() { toy in
            _ = try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "two-items-v1", route: "home"))
            let before = try await toy.call(AppCommands.snapshot, SnapshotRequest(scope: "app"))

            let badItem = await failure {
                try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "empty-v1", route: "detail", context: ["item": "a"]))
            }
            #expect(badItem?.code == .invalidParams)
            #expect(badItem?.details?["phase"] == "navigation")
            let badContext = await failure {
                try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "two-items-v1", route: "detail", context: ["other": "a"]))
            }
            #expect(badContext?.details?["field"] == "context.other")
            let badFixture = await failure {
                try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "missing-v1", route: "home"))
            }
            #expect(badFixture?.code == .fixtureNotFound)
            #expect(badFixture?.details?["phase"] == "fixture")

            let after = try await toy.call(AppCommands.snapshot, SnapshotRequest(scope: "app"))
            #expect(after.fields == before.fields)
            let finished = try await toy.call(AppCommands.events, EventsRequest(revision: before.revision)).events
            #expect(finished.compactMap(\.lifecycle).filter { $0.phase == .ended }.allSatisfy { $0.outcome == .failed })
        }
    }

    @Test func navigationReportsFailedLoadAndWaitsReturnBlockers() async throws {
        try await ToyHost.run() { toy in
            _ = try await toy.call(AppCommands.load, LoadFixture(fixture: "two-items-v1"))
            await MainActor.run { toy.app.failNextLoad = true }
            let failed = await failure { try await toy.call(AppCommands.open, OpenScreen(route: "detail", context: ["item": "a"])) }
            #expect(failed?.code == .notReady)
            let diagnostics = try await toy.call(AppCommands.diagnostics, DiagnosticsRequest(category: "items"))
            #expect(diagnostics.first?.code == "ITEM_LOAD_FAILED")
            let unknownCategory = await failure { try await toy.call(AppCommands.diagnostics, DiagnosticsRequest(category: "network")) }
            #expect(unknownCategory?.details?["field"] == "category")

            await MainActor.run { toy.app.loadDelay = .seconds(5) }
            let accepted = try await toy.client.call(AppCommands.open, OpenScreen(route: "detail", context: ["item": "b"], waitForReady: false))
            #expect(accepted.status == .accepted)
            let pending = try await toy.call(AppCommands.wait, WaitRequest(condition: "screen.ready", scope: "current-screen", failOnTimeout: false),
                                             timeoutMs: 400)
            #expect(!pending.satisfied)
            #expect(pending.blockers == ["item.load"])
            let timeout = await failure {
                try await toy.call(AppCommands.wait, WaitRequest(condition: "work.quiescent", scope: "current-screen"), timeoutMs: 300)
            }
            #expect(timeout?.code == .timeout)
            #expect(timeout?.details?["blockers"] == ["item.load"])
        }
    }

    @Test func operationAndLifecycleWaitsUseTheJournal() async throws {
        try await ToyHost.run() { toy in
            _ = try await toy.call(AppCommands.load, LoadFixture(fixture: "two-items-v1"))
            let opened = try await toy.call(AppCommands.open, OpenScreen(route: "detail", context: ["item": "a"], waitForReady: false))
            let operation = try #require(opened.operationId)
            let completed = try await toy.call(AppCommands.wait, WaitRequest(
                condition: "operation.completed", scope: "current-screen", arguments: ["operationId": .string(operation.uuidString)]))
            #expect(completed.lifecycle?.outcome == .completed)

            // A retained terminal span is still found after another screen opens.
            _ = try await toy.call(AppCommands.open, OpenScreen(route: "home"))
            let ended = try await toy.call(AppCommands.wait, WaitRequest(
                condition: "lifecycle.ended", scope: "current-screen", arguments: ["operationId": .string(operation.uuidString)]))
            #expect(ended.lifecycle?.id == operation)

            let unknown = await failure {
                try await toy.call(AppCommands.wait, WaitRequest(
                    condition: "operation.completed", scope: "current-screen", arguments: ["operationId": .string(UUID().uuidString)]))
            }
            #expect(unknown?.code == .conflict)
            let malformed = await failure {
                try await toy.call(AppCommands.wait, WaitRequest(condition: "operation.completed", scope: "current-screen", arguments: [:]))
            }
            #expect(malformed?.details?["field"] == "arguments.operationId")
            let field = try await toy.call(AppCommands.wait, WaitRequest(
                condition: "state.field_equals", scope: "app", arguments: ["field": "itemCount", "value": 2]))
            #expect(field.satisfied)
            let custom = try await toy.call(AppCommands.wait, WaitRequest(condition: "items.present", scope: "app"))
            #expect(custom.satisfied)
        }
    }

    @Test func actionsValidateInputEnablementAndRevision() async throws {
        try await ToyHost.run() { toy in
            let disabled = await failure { try await toy.call(AppCommands.invoke, ActionRequest(actionId: "detail.save", arguments: ["name": "x"])) }
            #expect(disabled?.code == .notReady)
            let missing = await failure { try await toy.call(AppCommands.invoke, ActionRequest(actionId: "detail.delete", arguments: [:])) }
            #expect(missing?.code == .actionNotFound)

            let screen = try await toy.call(AppCommands.prepare, PrepareScenario(fixture: "two-items-v1", route: "detail", context: ["item": "a"])).screen
            let tooLong = await failure {
                try await toy.call(AppCommands.invoke, ActionRequest(actionId: "detail.save", arguments: ["name": .string(String(repeating: "n", count: 20))]))
            }
            #expect(tooLong?.details?["field"] == "arguments.name")
            let saved = try await toy.call(AppCommands.invoke, ActionRequest(actionId: "detail.save", arguments: ["name": "new"],
                                                                             expectedRevision: screen.revision))
            #expect(saved.outcome == .completed)
            #expect(saved.screen.fields["savedName"] == "new")
            #expect(saved.revision == screen.revision + 1)
            let stale = await failure {
                try await toy.call(AppCommands.invoke, ActionRequest(actionId: "detail.save", arguments: ["name": "again"],
                                                                    expectedRevision: screen.revision))
            }
            #expect(stale?.code == .staleRevision)
        }
    }

    @Test func observeReturnsSnapshotWithDeltaAndResyncs() async throws {
        try await ToyHost.run() { toy in
            let start = try await toy.call(AppCommands.snapshot, SnapshotRequest(scope: "current-screen"))
            _ = try await toy.call(AppCommands.load, LoadFixture(fixture: "two-items-v1"))
            let observed = try await toy.call(AppCommands.observe, ObserveRequest(scope: "current-screen", sinceRevision: start.revision))
            #expect(observed.delta?.events.map(\.type) == ["fixture.loaded"])
            #expect(observed.screen.revision == observed.delta?.latestRevision)
            let unknownScope = await failure { try await toy.call(AppCommands.observe, ObserveRequest(scope: "window:other")) }
            #expect(unknownScope?.details?["field"] == "scope")
        }
    }

    @Test func sharedOperationsBuildTheSameParamsForCLIAndMCP() async throws {
        let wait = try #require(AgentOperation.all.first { $0.tool == "wait" })
        let operation = UUID().uuidString
        let params = try wait.params(["condition": "operation.completed", "arguments.operationId": .string(operation)])
        #expect(params["scope"] == "current-screen")
        #expect(params["arguments"] == ["operationId": .string(operation)])
        #expect(throws: Failure.self) { try wait.params(["scope": "current-screen"]) }

        // Every app-facing command has exactly one shared operation.
        let methods = Set(AgentOperation.all.map(\.method))
        let commands = [AppCommands.prepare.method, AppCommands.load.method, AppCommands.open.method, AppCommands.snapshot.method,
                        AppCommands.observe.method, AppCommands.wait.method, AppCommands.events.method, AppCommands.diagnostics.method,
                        AppCommands.actions.method, AppCommands.invoke.method]
        #expect(methods == Set(commands))
        #expect(AgentOperation.all.count == commands.count)
        #expect(AgentOperation.all.filter(\.mutating).map(\.tool).sorted() == ["fixtures", "invoke", "navigate", "prepare"])
    }
}
