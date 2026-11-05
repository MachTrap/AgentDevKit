import AgentDevKitCore
import Foundation

/// The protocol methods every adapter-backed host serves. Each runs on the main actor,
/// where the adapter and runtime live, so a snapshot and its revision are read together.
enum Builtins {
    static let conditionIds = ["screen.ready", "work.quiescent", "operation.completed", "lifecycle.ended", "state.field_equals"]

    static let builtinConditions: [Capabilities.ConditionCapability] = [
        .init(id: "screen.ready", argumentsSchema: ObjectSchema.empty.json),
        .init(id: "work.quiescent", argumentsSchema: ObjectSchema.empty.json),
        .init(id: "operation.completed", argumentsSchema: operationArguments.json),
        .init(id: "lifecycle.ended", argumentsSchema: operationArguments.json),
        .init(id: "state.field_equals", argumentsSchema: fieldArguments.json)
    ]

    static let operationArguments = ObjectSchema(["operationId": .uuid], required: ["operationId"])
    static let fieldArguments = ObjectSchema(["field": .string(maxLength: 128), "value": .value], required: ["field", "value"])

    static let scopeField = Schema.string(maxLength: 128)
    static let cursor = Schema.integer(minimum: 0)
    static let pageLimit = Schema.integer(minimum: 1, maximum: Int64(RevisionJournal.maxPageSize))

    static func commands<Adapter: AgentAdapter>(
        adapter: Adapter, runtime: AgentRuntime, catalog: AgentCatalog, allowMutations: Bool, waitMargin: Duration
    ) -> [AppCommand] {
        let engine = Engine(adapter: adapter, runtime: runtime, catalog: catalog, waitMargin: waitMargin)
        var commands = [
            AppCommand(AppCommands.snapshot, parameters: ObjectSchema(["scope": scopeField], required: ["scope"])) { input, _ in
                try engine.screen(input.scope)
            },
            AppCommand(AppCommands.observe, parameters: ObjectSchema(
                ["scope": scopeField, "sinceRevision": cursor, "limit": pageLimit], required: ["scope"]
            )) { input, _ in
                try StateObservation(screen: engine.screen(input.scope), journal: runtime.journal, request: input)
            },
            AppCommand(AppCommands.events, parameters: ObjectSchema(["revision": cursor, "limit": pageLimit], required: ["revision"])) { input, _ in
                try runtime.journal.since(input.revision, limit: input.limit ?? RevisionJournal.maxPageSize)
            },
            AppCommand(AppCommands.diagnostics, parameters: ObjectSchema([
                "severity": .string(maxLength: 16, oneOf: ["warning", "error"]),
                "category": .string(maxLength: 128),
                "limit": .integer(minimum: 1, maximum: 50)
            ])) { input, _ in
                try runtime.recentDiagnostics(input, categories: catalog.diagnosticCategories).map(engine.redact)
            },
            AppCommand(OperationCommands.list, parameters: .empty) { _, _ in
                runtime.operations()
            },
            AppCommand(AppCommands.actions, parameters: .empty) { _, _ in
                // Actions are mutations, so a read-only session lists none.
                (allowMutations ? catalog.actions : []).map { action in
                    ActionCapability(id: action.id, scope: action.scope, enabled: action.enabled(),
                                     inputSchema: action.input.json.objectValue ?? [:])
                }
            },
            AppCommand(AppCommands.wait, parameters: ObjectSchema([
                "condition": .string(maxLength: 128), "scope": scopeField, "arguments": .value, "failOnTimeout": .boolean
            ], required: ["condition", "scope"])) { input, context in
                try await engine.wait(input, context: context)
            }
        ]
        if !catalog.actions.isEmpty {
            commands.append(AppCommand(AppCommands.invoke, parameters: ObjectSchema(
                ["actionId": .string(maxLength: 128), "arguments": .value, "expectedRevision": cursor],
                required: ["actionId", "arguments"]
            ), accepted: { $0.outcome == .accepted }) { input, context in
                try await engine.invoke(input, context: context)
            })
        }
        let navigation = ObjectSchema(["route": .string(maxLength: 128), "context": .value, "waitForReady": .boolean],
                                      required: ["route"])
        if !catalog.routes.isEmpty {
            commands.append(AppCommand(AppCommands.open, parameters: navigation, accepted: { !$0.ready }) { input, context in
                let destination = try engine.resolve(route: input.route, context: input.context, fixture: nil)
                return try await engine.open(destination, wait: input.waitForReady ?? true, context: context, scenarioId: nil)
            })
        }
        if !catalog.fixtures.isEmpty {
            commands.append(AppCommand(AppCommands.load, parameters: ObjectSchema(["fixture": .string(maxLength: 128), "arguments": .value],
                                                                                 required: ["fixture"])) { input, context in
                try await engine.load(input.fixture, arguments: input.arguments, context: context)
            })
        }
        if !catalog.routes.isEmpty, !catalog.fixtures.isEmpty {
            var scenario = navigation
            scenario.properties["fixture"] = .string(maxLength: 128)
            scenario.properties["fixtureArguments"] = .value
            scenario.required.insert("fixture")
            commands.append(AppCommand(AppCommands.prepare, parameters: scenario, accepted: { !$0.screen.ready }) { input, context in
                try await engine.prepare(input, context: context)
            })
        }
        return commands
    }
}

/// Built-in behavior over one adapter. Isolated to the main actor with the adapter it drives.
@MainActor
private final class Engine<Adapter: AgentAdapter>: Sendable {
    let adapter: Adapter
    let runtime: AgentRuntime
    let catalog: AgentCatalog
    let waitMargin: Duration
    let primaryScope: String
    let conditions: [String: AgentCondition]

    nonisolated init(adapter: Adapter, runtime: AgentRuntime, catalog: AgentCatalog, waitMargin: Duration) {
        self.adapter = adapter
        self.runtime = runtime
        self.catalog = catalog
        self.waitMargin = waitMargin
        primaryScope = catalog.scopes.contains("current-screen") ? "current-screen" : catalog.scopes.first ?? "current-screen"
        conditions = Dictionary(catalog.conditions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func screen(_ scope: String) throws -> ScreenState {
        guard catalog.scopes.contains(scope) else {
            throw Failure(.invalidParams, "Snapshot scope is not registered.", details: ["field": "scope"])
        }
        let snapshot = try adapter.snapshot(scope: scope)
        return ScreenState(
            screenId: snapshot.screenId, windowId: snapshot.windowId, ready: snapshot.ready, revision: runtime.revision,
            scope: scope, fields: redact(snapshot.fields), operationId: snapshot.operationId,
            blockers: snapshot.blockers.isEmpty ? nil : snapshot.blockers
        )
    }

    private func deadline(_ context: CommandContext) -> ContinuousClock.Instant { context.deadline - waitMargin }

    // MARK: Redaction

    /// Replaces every app-declared secret in string values, recursively. Applied to all outgoing app fields.
    func redact(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        let secrets = adapter.secretValues().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !secrets.isEmpty else { return fields }
        func scrub(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text): .string(secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") })
            case .array(let items): .array(items.map(scrub))
            case .object(let object): .object(object.mapValues(scrub))
            default: value
            }
        }
        return fields.mapValues(scrub)
    }

    func redact(_ record: DiagnosticRecord) -> DiagnosticRecord {
        guard case .string(let message)? = redact(["m": .string(record.message)])["m"], message != record.message else { return record }
        return DiagnosticRecord(severity: record.severity, category: record.category, code: record.code, message: message,
                                timestamp: record.timestamp, correlationId: record.correlationId)
    }

    // MARK: Navigation and fixtures

    func resolve(route id: String, context: RouteContext?, fixture: String?) throws -> Adapter.NavigationTarget {
        guard let route = catalog.routes.first(where: { $0.id == id }) else {
            throw Failure(.routeNotFound, "Route is not registered.", details: ["field": "route"])
        }
        try route.context.validate(context ?? [:], prefix: "context.")
        return try adapter.resolve(route: id, context: context ?? [:], fixture: fixture)
    }

    func open(_ destination: Adapter.NavigationTarget, wait: Bool, context: CommandContext, scenarioId: UUID?) async throws -> ScreenState {
        try context.checkDeadline()
        let before = runtime.revision
        let presentation = adapter.present(destination, request: PresentationRequest(requestId: context.requestId, scenarioId: scenarioId))
        guard wait else { return try screen(primaryScope) }
        var blockers: [String] = []
        let ready = try await runtime.wait(until: deadline(context)) { () throws -> ScreenState? in
            switch adapter.readiness(of: presentation) {
            case .ready: return try screen(primaryScope)
            case .pending(let gates):
                blockers = gates
                return nil
            case .failed(let failure): throw failure
            case .superseded: throw Failure(.conflict, "Navigation was superseded.")
            }
        }
        guard let ready else {
            var details: [String: JSONValue] = ["blockers": .array(blockers.map(JSONValue.string))]
            if !screenOpened(since: before) {
                // The most common integration bug: the view's appearance callback never reports this presentation.
                details["hint"] = "No screen.opened event was recorded for this presentation. Check that the destination view reports its appearance for every presentation, for example with onAppear inside .id(presentationId)."
            }
            throw Failure(.timeout, "Screen did not become ready before the deadline.", retryable: true, details: details)
        }
        return ready
    }

    private func screenOpened(since revision: UInt64) -> Bool {
        guard let page = try? runtime.journal.since(revision) else { return true }
        return page.events.contains { $0.lifecycle?.kind == .screen && $0.lifecycle?.phase == .began }
    }

    func load(_ id: String, arguments: [String: JSONValue]? = nil, context: CommandContext) async throws -> FixtureState {
        guard catalog.fixtures.contains(id) else {
            throw Failure(.fixtureNotFound, "Fixture is not registered.", details: ["field": "fixture"])
        }
        let arguments = arguments ?? [:]
        if let schema = catalog.fixtureArguments[id] {
            try schema.validate(arguments, prefix: "arguments.")
        } else if let extra = arguments.keys.sorted().first {
            throw Failure(.invalidParams, "This fixture accepts no arguments.", details: ["field": .string("arguments." + extra)])
        }
        try context.checkDeadline()
        let fields = try await adapter.loadFixture(id, arguments: arguments, context: context)
        return FixtureState(fixture: id, revision: runtime.revision, fields: redact(fields))
    }

    func prepare(_ input: PrepareScenario, context: CommandContext) async throws -> ScenarioState {
        let result = try await runtime.withLifecycle(
            .scenario, name: "scenario.prepare", scope: "app", id: context.requestId, correlationId: context.requestId,
            accepted: { (state: ScenarioState) in !state.screen.ready }
        ) { span in
            // Resolve against the fixture before replacing any data, so a bad route leaves state intact.
            guard catalog.fixtures.contains(input.fixture) else {
                throw Self.phase(Failure(.fixtureNotFound, "Fixture is not registered.", details: ["field": "fixture"]), "fixture")
            }
            let destination: Adapter.NavigationTarget
            do { destination = try resolve(route: input.route, context: input.context, fixture: input.fixture) }
            catch { throw Self.phase(error, "navigation") }
            let fixture: FixtureState
            do { fixture = try await load(input.fixture, arguments: input.fixtureArguments, context: context) }
            catch { throw Self.phase(error, "fixture") }
            do {
                let screen = try await open(destination, wait: input.waitForReady ?? true, context: context, scenarioId: span?.id)
                return ScenarioState(fixture: fixture, screen: screen)
            } catch {
                throw Self.phase(error, "navigation")
            }
        }
        // Report the screen after the scenario span closed, so its revision covers the terminal event.
        return ScenarioState(fixture: result.fixture, screen: try screen(primaryScope))
    }

    private static func phase(_ error: any Error, _ phase: String) -> Failure {
        let failure = error as? Failure ?? (error is CancellationError
            ? Failure(.cancelled, "Request cancelled.")
            : Failure(.internalError, "Scenario preparation failed."))
        var details = failure.details ?? [:]
        details["phase"] = .string(phase)
        return Failure(failure.code, failure.message, retryable: failure.retryable, details: details)
    }

    // MARK: Actions

    func invoke(_ input: ActionRequest, context: CommandContext) async throws -> ActionResult {
        guard let action = catalog.actions.first(where: { $0.id == input.actionId }) else {
            throw Failure(.actionNotFound, "Action is not registered.", details: ["field": "actionId"])
        }
        if let expected = input.expectedRevision, expected != runtime.revision {
            throw Failure(.staleRevision, "State changed after the expected revision.", retryable: true,
                          details: ["expectedRevision": .integer(Int64(expected)), "latestRevision": .integer(Int64(runtime.revision))])
        }
        guard action.enabled() else { throw Failure(.notReady, "Action is unavailable on this screen.") }
        try action.input.validate(input.arguments, prefix: "arguments.")
        try context.checkDeadline()
        let outcome = try await action.run(input.arguments, context)
        return ActionResult(actionId: action.id, outcome: outcome.outcome, revision: runtime.revision,
                            operationId: outcome.operationId, screen: try screen(primaryScope))
    }

    // MARK: Waiting

    private enum Evaluation {
        case satisfied(LifecycleEvent?)
        case pending([String])
    }

    func wait(_ input: WaitRequest, context: CommandContext) async throws -> WaitState {
        _ = try screen(input.scope)
        let arguments = input.arguments ?? [:]
        let evaluate = try evaluator(input.condition, arguments: arguments)
        var blockers: [String] = []
        let result = try await runtime.wait(until: deadline(context)) { () throws -> WaitState? in
            let state = try screen(input.scope)
            switch try evaluate(state) {
            case .satisfied(let lifecycle): return WaitState(screen: state, lifecycle: lifecycle)
            case .pending(let gates):
                blockers = gates
                return nil
            }
        }
        if let result { return result }
        if input.failOnTimeout == false {
            return WaitState(satisfied: false, blockers: blockers, screen: try screen(input.scope))
        }
        throw Failure(.timeout, "Condition did not settle before the deadline.", retryable: true,
                      details: ["blockers": .array(blockers.map(JSONValue.string))])
    }

    private func evaluator(_ id: String, arguments: [String: JSONValue]) throws -> (ScreenState) throws -> Evaluation {
        func validated(_ schema: ObjectSchema) throws -> [String: JSONValue] {
            try schema.validate(arguments, prefix: "arguments.")
            return arguments
        }
        switch id {
        case "screen.ready":
            _ = try validated(.empty)
            let presentation = adapter.currentPresentation
            return { [adapter] screen in
                guard let presentation else {
                    return screen.ready ? .satisfied(nil) : .pending(screen.blockers ?? ["screen.ready"])
                }
                guard adapter.currentPresentation == presentation else { throw Failure(.conflict, "Screen changed while waiting.") }
                switch adapter.readiness(of: presentation) {
                case .ready: return .satisfied(nil)
                case .pending(let gates): return .pending(gates)
                case .failed(let failure): throw failure
                case .superseded: throw Failure(.conflict, "Screen changed while waiting.")
                }
            }
        case "work.quiescent":
            _ = try validated(.empty)
            return { [runtime] _ in
                let active = runtime.journal.activeLifecycles(.work).map(\.name)
                return active.isEmpty ? .satisfied(nil) : .pending(active)
            }
        case "operation.completed", "lifecycle.ended":
            let operation = try validated(Builtins.operationArguments)["operationId"]?.stringValue
            guard let operation, let spanId = UUID(uuidString: operation) else {
                throw Failure(.invalidParams, "Field arguments.operationId must be a UUID.", details: ["field": "arguments.operationId"])
            }
            // operation.completed requires an operation the journal knows. lifecycle.ended may wait for one to begin.
            let requireTracked = id == "operation.completed"
            return { [runtime] _ in
                if let terminal = runtime.journal.terminalLifecycle(spanId) { return .satisfied(terminal) }
                if let active = runtime.journal.activeLifecycle(spanId) { return .pending([active.name]) }
                if requireTracked { throw Failure(.conflict, "Operation is not tracked or no longer retained.") }
                return .pending(["lifecycle.ended"])
            }
        case "state.field_equals":
            let fields = try validated(Builtins.fieldArguments)
            let field = fields["field"]?.stringValue ?? ""
            let value = fields["value"] ?? .null
            return { screen in screen.fields[field] == value ? .satisfied(nil) : .pending(["state.field_equals"]) }
        default:
            guard let condition = conditions[id] else {
                throw Failure(.invalidParams, "Condition is not registered.", details: ["field": "condition"])
            }
            let checked = try validated(condition.arguments)
            return { screen in
                switch try condition.evaluate(checked, screen) {
                case .satisfied: return .satisfied(nil)
                case .pending(let gates): return .pending(gates)
                }
            }
        }
    }

}
