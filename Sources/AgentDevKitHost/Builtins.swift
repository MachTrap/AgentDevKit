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

    /// Built-in conditions, plus `invariants.hold` when the catalog registers invariants.
    static func builtinConditions(_ catalog: AgentCatalog) -> [Capabilities.ConditionCapability] {
        builtinConditions + (catalog.invariants.isEmpty ? [] : [.init(id: "invariants.hold", argumentsSchema: invariantArguments.json)])
    }

    static let operationArguments = ObjectSchema(["operationId": .uuid], required: ["operationId"])
    static let fieldArguments = ObjectSchema(["field": .string(maxLength: 128), "value": .value], required: ["field", "value"])
    static let invariantArguments = ObjectSchema(["ids": .array(.string(maxLength: 128), maxItems: 64)])

    /// Feature names advertised in capabilities. Names with a dot are methods and appear only when served.
    static func features(_ catalog: AgentCatalog, allowMutations: Bool) -> [String] {
        var features = ["conditionAliases", "suggestions", "operations.status", "privacy.status", "trackedOperations"]
        if !catalog.invariants.isEmpty { features += ["invariants.list", "observe.violations"] }
        if !catalog.experiments.isEmpty { features.append("experiments.run") }
        if catalog.operatorPrompts { features += ["operator.ask", "operator.answer"] }
        if catalog.ui.contains(.capture) { features += ["ui.surfaces", "capture.modes", "capture.revision"] }
        if catalog.ui.contains(.capture) && catalog.ui.contains(.tree) { features.append("ui.snapshot") }
        if catalog.ui.contains(.tree) { features += ["tree.lint", "tree.paths", "tree.revision"] }
        if catalog.ui.contains(.press) { features.append("press.locators") }
        if catalog.ui.contains(.perform) { features.append("ui.perform") }
        if catalog.ui.contains(.input) { features += ["ui.key", "ui.hover", "ui.scroll"] }
        return features
    }

    /// A ready-to-run CLI line for a condition, reusing the caller's arguments where they fit.
    static func waitExample(_ condition: String, arguments: [String: JSONValue], scope: String) -> String {
        var line = "agentdevctl wait --condition \(condition)"
        if scope != "current-screen" { line += " --scope \(NameSuggestions.shellQuoted(scope))" }
        switch condition {
        case "state.field_equals":
            let field = arguments["field"]?.stringValue ?? "FIELD"
            // Text that is not JSON is passed bare; the CLI reads `--value results` as the string "results".
            let value = arguments["value"].map { value -> String in
                if case .string(let text) = value, (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) == nil { return text }
                return NameSuggestions.compactJSON(value)
            } ?? "VALUE"
            line += " --field \(NameSuggestions.shellQuoted(field)) --value \(NameSuggestions.shellQuoted(value))"
        case "operation.completed", "lifecycle.ended":
            line += " --operation \(arguments["operationId"]?.stringValue ?? "OPERATION_ID")"
        default:
            if !arguments.isEmpty { line += " --args \(NameSuggestions.shellQuoted(NameSuggestions.compactJSON(.object(arguments))))" }
        }
        return line
    }

    static let scopeField = Schema.string(maxLength: 128)
    static let cursor = Schema.integer(minimum: 0)
    static let pageLimit = Schema.integer(minimum: 1, maximum: Int64(RevisionJournal.maxPageSize))

    static func commands<Adapter: AgentAdapter>(
        adapter: Adapter, runtime: AgentRuntime, catalog: AgentCatalog, allowMutations: Bool, waitMargin: Duration,
        ledger: RequestLedger = RequestLedger()
    ) -> (commands: [AppCommand], install: @MainActor @Sendable () -> Void) {
        let engine = Engine(adapter: adapter, runtime: runtime, catalog: catalog, waitMargin: waitMargin, ledger: ledger)
        let install: @MainActor @Sendable () -> Void = { engine.install() }
        var commands = [
            AppCommand(AppCommands.snapshot, parameters: ObjectSchema(["scope": scopeField], required: ["scope"])) { input, _ in
                try engine.screen(input.scope)
            },
            AppCommand(AppCommands.observe, parameters: ObjectSchema(
                ["scope": scopeField, "sinceRevision": cursor, "limit": pageLimit], required: ["scope"]
            )) { input, _ in
                try engine.observe(input)
            },
            AppCommand(AppCommands.events, parameters: ObjectSchema(["revision": cursor, "limit": pageLimit], required: ["revision"])) { input, _ in
                try runtime.journal.since(input.revision, limit: input.limit ?? RevisionJournal.maxPageSize)
            },
            AppCommand(AppCommands.diagnostics, parameters: ObjectSchema([
                "severity": .string(maxLength: 16, oneOf: ["warning", "error"]),
                "category": .string(maxLength: 128),
                "limit": .integer(minimum: 1, maximum: 50)
            ])) { input, _ in
                try runtime.recentDiagnostics(input, categories: catalog.allDiagnosticCategories).map(engine.redact)
            },
            AppCommand(OperationCommands.list, parameters: .empty) { _, _ in
                runtime.operations()
            },
            AppCommand(OperationCommands.status, parameters: ObjectSchema(["requestId": .uuid, "operationId": .uuid])) { input, _ in
                try engine.status(input)
            },
            AppCommand(PrivacyCommands.status, parameters: .empty) { _, _ in
                PrivacyProbe.status()
            },
            AppCommand(AppCommands.actions, parameters: .empty) { _, _ in
                // Actions are mutations, so a read-only session lists none.
                (allowMutations ? catalog.actions : []).map { action in
                    ActionCapability(id: action.id, scope: action.scope, enabled: action.enabled(),
                                     inputSchema: action.input.json.objectValue ?? [:], presentsUI: action.presentsUI)
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
            ), accepted: { $0.outcome == .accepted }, promote: { input, context in
                ActionResult(actionId: input.actionId, outcome: .accepted, revision: runtime.revision, operationId: context.requestId,
                             screen: try engine.screen(engine.primaryScope))
            }) { input, context in
                try await engine.invoke(input, context: context)
            })
        }
        if !catalog.invariants.isEmpty {
            commands.append(AppCommand(InvariantCommands.list, parameters: .empty) { _, _ in
                engine.invariantReport()
            })
        }
        if !catalog.experiments.isEmpty {
            commands.append(AppCommand(ExperimentCommands.run, parameters: ObjectSchema(
                ["experimentId": .string(maxLength: 128), "arguments": .value], required: ["experimentId"]
            )) { input, context in
                try await engine.experiment(input, context: context, allowMutations: allowMutations)
            })
        }
        if catalog.operatorPrompts {
            commands.append(AppCommand(OperatorCommands.ask, parameters: ObjectSchema([
                "question": .string(maxLength: 1_000), "options": .array(.string(maxLength: 64), maxItems: 6),
                "allowNotes": .boolean, "answerTimeoutMs": .integer(minimum: 1_000, maximum: 1_800_000)
            ], required: ["question"])) { input, context in
                try engine.ask(input, context: context)
            })
            if allowMutations {
                // Only a session that can ask has answers to read.
                commands.append(AppCommand(OperatorCommands.answer, parameters: ObjectSchema(["operationId": .uuid], required: ["operationId"])) { input, _ in
                    try engine.answer(input.operationId)
                })
            }
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
                                                                                 required: ["fixture"]), promote: { input, context in
                FixtureState(fixture: input.fixture, revision: runtime.revision, operationId: context.requestId)
            }) { input, context in
                try await engine.load(input.fixture, arguments: input.arguments, context: context)
            })
        }
        if !catalog.routes.isEmpty, !catalog.fixtures.isEmpty {
            var scenario = navigation
            scenario.properties["fixture"] = .string(maxLength: 128)
            scenario.properties["fixtureArguments"] = .value
            scenario.required.insert("fixture")
            commands.append(AppCommand(AppCommands.prepare, parameters: scenario, accepted: { !$0.screen.ready }, promote: { input, context in
                ScenarioState(fixture: FixtureState(fixture: input.fixture, revision: runtime.revision),
                              screen: try engine.screen(engine.primaryScope), operationId: context.requestId)
            }) { input, context in
                try await engine.prepare(input, context: context)
            })
        }
        return (commands, install)
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
    let ledger: RequestLedger

    nonisolated init(adapter: Adapter, runtime: AgentRuntime, catalog: AgentCatalog, waitMargin: Duration, ledger: RequestLedger) {
        self.adapter = adapter
        self.runtime = runtime
        self.catalog = catalog
        self.waitMargin = waitMargin
        self.ledger = ledger
        primaryScope = catalog.scopes.contains("current-screen") ? "current-screen" : catalog.scopes.first ?? "current-screen"
        conditions = Dictionary(catalog.conditions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Main-actor setup at host start: invariant evaluation and ledger wake-ups.
    func install() {
        ledger.setOnChange { [weak runtime] in
            Task { @MainActor in runtime?.notifyChange() }
        }
        guard !catalog.invariants.isEmpty, runtime.invariantEngine == nil else { return }
        runtime.invariantEngine = InvariantEngine(catalog.invariants) { [unowned self] scope in try self.screen(scope) }
        runtime.invariantEngine?.evaluate(runtime)
    }

    func screen(_ scope: String) throws -> ScreenState {
        guard catalog.scopes.contains(scope) else {
            throw Failure.unknownName(kind: "scope", field: "scope", name: scope, valid: catalog.scopes) {
                "agentdevctl state --scope \(NameSuggestions.shellQuoted($0))"
            }
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

    func observe(_ input: ObserveRequest) throws -> StateObservation {
        var observation = try StateObservation(screen: screen(input.scope), journal: runtime.journal, request: input)
        if let engine = runtime.invariantEngine {
            engine.evaluate(runtime)
            let violations = engine.violations(since: input.sinceRevision ?? 0)
            observation.violations = violations.isEmpty ? nil : Array(violations.suffix(64))
        }
        return observation
    }

    func resolve(route id: String, context: RouteContext?, fixture: String?) throws -> Adapter.NavigationTarget {
        guard let route = catalog.routes.first(where: { $0.id == id }) else {
            throw Failure.unknownName(.routeNotFound, kind: "route", field: "route", name: id, valid: catalog.routes.map(\.id)) {
                "agentdevctl navigation open --route \(NameSuggestions.shellQuoted($0))"
            }
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

    private func unknownFixture(_ id: String) -> Failure {
        Failure.unknownName(.fixtureNotFound, kind: "fixture", field: "fixture", name: id, valid: catalog.fixtures) {
            "agentdevctl fixtures load --fixture \(NameSuggestions.shellQuoted($0))"
        }
    }

    func load(_ id: String, arguments: [String: JSONValue]? = nil, context: CommandContext) async throws -> FixtureState {
        guard catalog.fixtures.contains(id) else { throw unknownFixture(id) }
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
            guard catalog.fixtures.contains(input.fixture) else { throw Self.phase(unknownFixture(input.fixture), "fixture") }
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
            throw Failure.unknownName(.actionNotFound, kind: "action", field: "actionId", name: input.actionId,
                                      valid: catalog.actions.map(\.id)) { id in
                let schema = self.catalog.actions.first { $0.id == id }?.input
                let arguments = schema.map { Self.placeholder($0) } ?? [:]
                return "agentdevctl action invoke --id \(NameSuggestions.shellQuoted(id)) --args \(NameSuggestions.shellQuoted(NameSuggestions.compactJSON(.object(arguments))))"
            }
        }
        if let expected = input.expectedRevision, expected != runtime.revision {
            throw Failure(.staleRevision, "State changed after the expected revision.", retryable: true,
                          details: ["expectedRevision": .integer(Int64(expected)), "latestRevision": .integer(Int64(runtime.revision))])
        }
        guard action.enabled() else { throw Failure(.notReady, "Action is unavailable on this screen.") }
        try action.input.validate(input.arguments, prefix: "arguments.")
        try context.checkDeadline()
        if action.presentsUI {
            // Panels and alerts wait for a person; never hold the request open for them.
            let arguments = input.arguments
            let extended = context.extending(to: .now + AgentRuntime.trackedCeiling)
            let tracked = runtime.track(action.id, scope: action.scope, id: context.requestId, correlationId: context.requestId,
                                        presentsUI: true) {
                let outcome = try await action.run(arguments, extended)
                if outcome.outcome == .accepted, let inner = outcome.operationId {
                    // The action started further tracked work; finish when that does.
                    _ = try await self.runtime.wait(until: .now + AgentRuntime.trackedCeiling) { () -> Bool? in
                        self.runtime.journal.terminalLifecycle(inner) != nil || self.runtime.trackedOutcome(inner) != nil ? true : nil
                    }
                }
            }
            return ActionResult(actionId: action.id, outcome: tracked.outcome, revision: runtime.revision,
                                operationId: tracked.operationId, screen: try screen(primaryScope))
        }
        let outcome = try await action.run(input.arguments, context)
        return ActionResult(actionId: action.id, outcome: outcome.outcome, revision: runtime.revision,
                            operationId: outcome.operationId, screen: try screen(primaryScope))
    }

    /// Placeholder arguments for an example: each required field named in upper case.
    static func placeholder(_ schema: ObjectSchema) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: schema.required.sorted().map { name -> (String, JSONValue) in
            switch schema.properties[name] {
            case .integer?, .number?: (name, 0)
            case .boolean?: (name, true)
            case .string(_, let values)?: (name, .string(values?.first ?? name.uppercased()))
            case .array?: (name, [])
            case .object?: (name, [:])
            default: (name, .string(name.uppercased()))
            }
        })
    }

    // MARK: Operation status

    func status(_ input: OperationStatusRequest) throws -> OperationStatus {
        guard (input.requestId == nil) != (input.operationId == nil) else {
            throw Failure(.invalidParams, "Pass exactly one of requestId or operationId.", details: ["field": "requestId"])
        }
        if let requestId = input.requestId, let entry = ledger.entry(request: requestId) {
            // An accepted request whose work runs as a tracked operation reports that operation's outcome.
            if entry.state == .pending, let operation = entry.operationId, let tracked = runtimeStatus(operation), tracked.state != .pending {
                return OperationStatus(state: tracked.state, requestId: requestId, operationId: operation, method: entry.method,
                                       revision: tracked.revision, code: tracked.code, reason: tracked.reason)
            }
            return status(of: entry)
        }
        let id = input.operationId ?? input.requestId!
        // A request promoted to `accepted` keeps its final result in the ledger. Otherwise the span or tracked
        // operation is the better witness: a request can complete while the work it started fails later.
        if let entry = ledger.entry(operation: id), entry.operationId == id, entry.state != .pending { return status(of: entry) }
        if let tracked = runtimeStatus(id) { return tracked }
        if let entry = ledger.entry(operation: id) { return status(of: entry) }
        return OperationStatus(state: .unknown, requestId: input.requestId, operationId: input.operationId)
    }

    /// What the runtime knows about a span or tracked operation.
    private func runtimeStatus(_ id: UUID) -> OperationStatus? {
        if let tracked = runtime.trackedOutcome(id) {
            let state: OperationStatus.State = switch tracked.outcome {
            case .failed: .failed
            case .cancelled, .superseded: .cancelled
            default: .completed
            }
            return OperationStatus(state: state, operationId: id, revision: tracked.revision, code: tracked.code, reason: tracked.reason)
        }
        if let active = runtime.journal.activeLifecycle(id) {
            return OperationStatus(state: .pending, operationId: id, method: active.name,
                                   awaitingUser: runtime.presentingUI.contains(id) ? runtime.awaitingUser : nil)
        }
        if let terminal = runtime.journal.terminalLifecycle(id) {
            let state: OperationStatus.State = switch terminal.outcome {
            case .failed?: .failed
            case .cancelled?, .superseded?: .cancelled
            default: .completed
            }
            return OperationStatus(state: state, operationId: id, method: terminal.name)
        }
        return nil
    }

    private func status(of entry: RequestLedger.Entry) -> OperationStatus {
        let awaiting = entry.state == .pending && entry.operationId.map(runtime.presentingUI.contains) == true ? runtime.awaitingUser : nil
        return OperationStatus(state: entry.state, requestId: entry.requestId, operationId: entry.operationId, method: entry.method,
                               revision: entry.revision, code: entry.code, reason: entry.reason, result: entry.result, awaitingUser: awaiting,
                               details: entry.details)
    }

    // MARK: Invariants

    func invariantReport() -> InvariantReport {
        guard let engine = runtime.invariantEngine else {
            return InvariantReport(revision: runtime.revision, invariants: [], violations: [], truncated: false)
        }
        engine.evaluate(runtime)
        return InvariantReport(revision: runtime.revision, invariants: engine.states, violations: Array(engine.violations.suffix(64)),
                               truncated: engine.violations.count > 64 || engine.droppedViolations)
    }

    // MARK: Experiments

    func experiment(_ input: ExperimentRequest, context: CommandContext, allowMutations: Bool) async throws -> ExperimentResult {
        let visible = catalog.experiments.filter { allowMutations || $0.readOnly }
        guard let experiment = visible.first(where: { $0.id == input.experimentId }) else {
            if catalog.experiments.contains(where: { $0.id == input.experimentId }) {
                throw Failure(.permissionDenied, "This experiment changes the app. Use a mutation session.")
            }
            throw Failure.unknownName(kind: "experiment", field: "experimentId", name: input.experimentId, valid: visible.map(\.id)) {
                "agentdevctl experiment run --id \(NameSuggestions.shellQuoted($0))"
            }
        }
        let arguments = input.arguments ?? [:]
        try experiment.input.validate(arguments, prefix: "arguments.")
        let clock = ContinuousClock()
        let started = clock.now
        let fields: [String: JSONValue]
        do { fields = redact(try await experiment.run(arguments, context)) } catch {
            runtime.diagnose(DiagnosticRecord(severity: .error, category: "experiment", code: experiment.id,
                                              message: Self.bounded("inputs=\(NameSuggestions.compactJSON(.object(redact(arguments)))) failed",
                                                                    1_000), correlationId: context.requestId))
            throw error
        }
        let elapsed = started.duration(to: clock.now).components
        let durationMs = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        runtime.diagnose(DiagnosticRecord(
            severity: .warning, category: "experiment", code: experiment.id,
            message: Self.bounded("inputs=\(NameSuggestions.compactJSON(.object(redact(arguments)))) results=\(NameSuggestions.compactJSON(.object(fields)))", 1_000),
            correlationId: context.requestId))
        return ExperimentResult(experimentId: experiment.id, fields: fields, durationMs: durationMs, revision: runtime.revision)
    }

    static func bounded(_ text: String, _ bytes: Int) -> String { ScreenSnapshot.preview(text, maxBytes: bytes) }

    // MARK: Operator prompts

    func ask(_ input: OperatorQuestion, context: CommandContext) throws -> OperatorTicket {
        let options = input.options ?? ["OK"]
        guard !options.isEmpty, options.allSatisfy({ !$0.isEmpty }),
              !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(.invalidParams, "A question and nonempty options are required.", details: ["field": "options"])
        }
        let id = context.requestId
        let timeout = Duration.milliseconds(input.answerTimeoutMs ?? 300_000)
        runtime.recordQuestion(id, question: input.question)
        runtime.diagnose(DiagnosticRecord(severity: .warning, category: "operator", code: "OPERATOR_ASKED",
                                          message: Self.bounded("Asked: \(input.question)", 600), correlationId: id))
        let prompt = OperatorPrompt(id: id, question: input.question, options: options, allowNotes: input.allowNotes ?? false)
        runtime.track("operator.ask", scope: "app", id: id, correlationId: id, presentsUI: true) { [runtime] in
            let reply = await prompt.ask(timeout: timeout)
            runtime.recordAnswer(id, answer: reply?.answer, notes: reply?.notes)
            runtime.diagnose(DiagnosticRecord(
                severity: .warning, category: "operator", code: reply == nil ? "OPERATOR_UNANSWERED" : "OPERATOR_ANSWERED",
                message: Self.bounded(reply.map { "Answered: \($0.answer)\($0.notes.map { " notes: \($0)" } ?? "")" } ?? "No answer before the timeout.", 600),
                correlationId: id))
            if reply == nil { throw Failure(.timeout, "unanswered") }
        }
        return OperatorTicket(operationId: id, revision: runtime.revision)
    }

    func answer(_ id: UUID) throws -> OperatorAnswer {
        guard let answer = runtime.operatorAnswers[id] else {
            throw Failure(.invalidParams, "No question with this operation ID is retained.", details: ["field": "operationId"])
        }
        return answer
    }

    // MARK: Waiting

    private enum Evaluation {
        case satisfied(LifecycleEvent?)
        case pending([String])
    }

    func wait(_ input: WaitRequest, context: CommandContext) async throws -> WaitState {
        _ = try screen(input.scope)
        let arguments = input.arguments ?? [:]
        let canonical = try canonicalCondition(input.condition, arguments: arguments, scope: input.scope)
        let evaluate = try evaluator(canonical, arguments: arguments)
        var blockers: [String] = []
        let result = try await runtime.wait(until: deadline(context)) { () throws -> WaitState? in
            let state = try screen(input.scope)
            switch try evaluate(state) {
            case .satisfied(let lifecycle): return WaitState(screen: state, lifecycle: lifecycle, condition: canonical)
            case .pending(let gates):
                blockers = gates
                return nil
            }
        }
        if let result { return result }
        if input.failOnTimeout == false {
            return WaitState(satisfied: false, blockers: blockers, screen: try screen(input.scope), condition: canonical)
        }
        throw Failure(.timeout, "Condition did not settle before the deadline.", retryable: true,
                      details: ["blockers": .array(blockers.map(JSONValue.string))])
    }

    var conditionIds: [String] {
        Builtins.conditionIds + (catalog.invariants.isEmpty ? [] : ["invariants.hold"]) + catalog.conditions.map(\.id)
    }

    /// The registered ID for a condition name, accepting camelCase and case variants of registered IDs.
    func canonicalCondition(_ id: String, arguments: [String: JSONValue], scope: String) throws -> String {
        let known = conditionIds
        if known.contains(id) { return id }
        if let alias = NameSuggestions.alias(id, in: known) { return alias }
        throw Failure.unknownName(kind: "condition", field: "condition", name: id, valid: known) {
            Builtins.waitExample($0, arguments: arguments, scope: scope)
        }
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
            // operation.completed requires an operation the journal or request ledger knows.
            // lifecycle.ended may wait for one to begin.
            let requireTracked = id == "operation.completed"
            return { [runtime, ledger] _ in
                if let terminal = runtime.journal.terminalLifecycle(spanId) { return .satisfied(terminal) }
                if let active = runtime.journal.activeLifecycle(spanId) { return .pending([active.name]) }
                if runtime.trackedOutcome(spanId) != nil { return .satisfied(nil) }
                if requireTracked, let entry = ledger.entry(operation: spanId) {
                    if entry.state == .pending { return .pending([entry.method]) }
                    if entry.state == .completed { return .satisfied(nil) }
                    throw Failure(.conflict, "Operation \(entry.state.rawValue): \(entry.code ?? "")", details: [
                        "state": .string(entry.state.rawValue), "code": entry.code.map(JSONValue.string) ?? .null
                    ])
                }
                if requireTracked { throw Failure(.conflict, "Operation is not tracked or no longer retained.") }
                return .pending(["lifecycle.ended"])
            }
        case "invariants.hold":
            let ids = try validated(Builtins.invariantArguments)["ids"]?.arrayValue?.compactMap(\.stringValue)
            if let unknown = ids?.first(where: { !(runtime.invariantEngine?.ids ?? []).contains($0) }) {
                throw Failure.unknownName(kind: "invariant", field: "arguments.ids", name: unknown, valid: runtime.invariantEngine?.ids ?? [])
            }
            return { [runtime] _ in
                guard let engine = runtime.invariantEngine else { return .satisfied(nil) }
                engine.evaluate(runtime)
                let failing = engine.failing(ids)
                return failing.isEmpty ? .satisfied(nil) : .pending(failing.map { "invariant:" + $0 })
            }
        case "state.field_equals":
            let fields = try validated(Builtins.fieldArguments)
            let field = fields["field"]?.stringValue ?? ""
            let value = fields["value"] ?? .null
            return { screen in screen.fields[field] == value ? .satisfied(nil) : .pending(["state.field_equals"]) }
        default:
            guard let condition = conditions[id] else {
                throw Failure.unknownName(kind: "condition", field: "condition", name: id, valid: conditionIds)
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
