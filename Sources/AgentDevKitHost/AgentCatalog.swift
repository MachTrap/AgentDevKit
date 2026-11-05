import AgentDevKitCore
import Foundation

/// A navigable route. The host validates `context` before calling the adapter.
public struct AgentRoute: Sendable {
    public let id: String
    public let context: ObjectSchema
    public let windowId: String?
    public let accessibilityId: String?
    public let readinessGates: [String]

    public init(_ id: String, context: ObjectSchema = .empty, windowId: String? = nil,
                accessibilityId: String? = nil, readinessGates: [String] = []) {
        self.id = id
        self.context = context
        self.windowId = windowId
        self.accessibilityId = accessibilityId
        self.readinessGates = readinessGates
    }

    var capability: Capabilities.RouteCapability {
        .init(id: id, contextSchema: context.json, windowId: windowId,
              accessibilityId: accessibilityId, readinessGates: readinessGates)
    }
}

/// The result of a semantic action.
public struct ActionOutcome: Sendable {
    public let outcome: ActionResult.Outcome
    public let operationId: UUID?

    public static let completed = ActionOutcome(outcome: .completed, operationId: nil)
    public static func completed(operationId: UUID) -> ActionOutcome { .init(outcome: .completed, operationId: operationId) }
    /// The action started tracked work that is still running.
    public static func accepted(operationId: UUID) -> ActionOutcome { .init(outcome: .accepted, operationId: operationId) }
}

/// A registered semantic action. It is not a physical click, so it cannot prove hit testing or focus.
public struct AgentAction: Sendable {
    public let id: String
    public let scope: String
    public let input: ObjectSchema
    /// The action opens a panel, sheet or alert that waits for a person. The host always runs it as a tracked
    /// operation and answers `accepted` at once, never TIMEOUT. `operations.list` reports `awaitingUser`.
    public let presentsUI: Bool
    let enabled: @MainActor @Sendable () -> Bool
    let run: @MainActor @Sendable ([String: JSONValue], CommandContext) async throws -> ActionOutcome

    public init<Input: Decodable>(
        _ id: String, scope: String, input: ObjectSchema, as type: Input.Type, presentsUI: Bool = false,
        enabled: @escaping @MainActor @Sendable () -> Bool = { true },
        run: @escaping @MainActor @Sendable (Input, CommandContext) async throws -> ActionOutcome
    ) {
        self.id = id
        self.scope = scope
        self.input = input
        self.presentsUI = presentsUI
        self.enabled = enabled
        self.run = { arguments, context in
            let value: Input
            do { value = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(arguments)) }
            catch {
                throw Failure(.invalidParams, "Action arguments do not match the input schema.",
                              details: decodingDetails(error).map { ["field": .string("arguments." + ($0["field"]?.stringValue ?? ""))] })
            }
            return try await run(value, context)
        }
    }
}

/// Outcome of one condition evaluation.
public enum ConditionResult: Sendable {
    case satisfied
    case pending(blockers: [String])
}

/// An app-specific `runtime.wait` condition, re-evaluated after every runtime change.
public struct AgentCondition: Sendable {
    public let id: String
    public let arguments: ObjectSchema
    let evaluate: @MainActor @Sendable ([String: JSONValue], ScreenState) throws -> ConditionResult

    public init(
        _ id: String, arguments: ObjectSchema = .empty,
        evaluate: @escaping @MainActor @Sendable (_ arguments: [String: JSONValue], _ screen: ScreenState) throws -> ConditionResult
    ) {
        self.id = id
        self.arguments = arguments
        self.evaluate = evaluate
    }
}

/// Result of one invariant evaluation.
public enum InvariantResult: Sendable, Equatable {
    case holds
    /// Bounded, app-defined facts such as counts or IDs. Never user content or secrets.
    case violated(details: [String: JSONValue])

    public static var violated: InvariantResult { .violated(details: [:]) }
}

/// A property of app state that must hold after every change, such as "no queued item is still drawn on the map".
/// The runtime evaluates it on the main actor after each recorded change, debounced to the next run-loop turn,
/// and reports each transition to violated once, as a diagnostic with category `invariant`.
public struct AgentInvariant: Sendable {
    public let id: String
    public let scope: String
    /// Evaluations slower than this are flagged `overBudget`.
    public let budgetMicros: Int
    let evaluate: @MainActor @Sendable (ScreenState) throws -> InvariantResult

    public init(_ id: String, scope: String = "current-screen", budgetMicros: Int = 2_000,
                evaluate: @escaping @MainActor @Sendable (_ screen: ScreenState) throws -> InvariantResult) {
        self.id = id
        self.scope = scope
        self.budgetMicros = max(1, budgetMicros)
        self.evaluate = evaluate
    }
}

/// An investigation probe, kept apart from product actions. Every run is recorded as a diagnostic with
/// category `experiment`, its inputs and its results. Read-only probes run in read-only sessions too.
public struct AgentExperiment: Sendable {
    public let id: String
    public let input: ObjectSchema
    public let readOnly: Bool
    let run: @MainActor @Sendable ([String: JSONValue], CommandContext) async throws -> [String: JSONValue]

    public init(_ id: String, input: ObjectSchema = .empty, readOnly: Bool = true,
                run: @escaping @MainActor @Sendable (_ arguments: [String: JSONValue], CommandContext) async throws -> [String: JSONValue]) {
        self.id = id
        self.input = input
        self.readOnly = readOnly
        self.run = run
    }

    var capability: Capabilities.ExperimentCapability {
        .init(id: id, inputSchema: input.json, readOnly: readOnly)
    }
}

/// Everything an app registers. The host derives both its method table and its
/// capabilities from this value, so advertised and served features cannot drift.
public struct AgentCatalog: Sendable {
    public var scopes: [String]
    public var routes: [AgentRoute]
    public var fixtures: [String]
    /// Optional argument schemas for fixtures, keyed by fixture ID. Fixtures without one accept no arguments.
    public var fixtureArguments: [String: ObjectSchema]
    public var actions: [AgentAction]
    public var conditions: [AgentCondition]
    public var lifecycle: [LifecycleCapability]
    public var diagnosticCategories: [String]
    /// Extra typed commands for app needs the built-ins do not cover.
    public var commands: [AppCommand]
    /// In-process UI tools to serve. Capture and tree are reads of the app's own windows; press is a
    /// mutation. Captures show whatever the window shows, so enable them only for Testing builds.
    public var ui: UIAccess
    /// Properties evaluated after every change. See `AgentInvariant`.
    public var invariants: [AgentInvariant]
    /// Investigation probes. See `AgentExperiment`.
    public var experiments: [AgentExperiment]
    /// Serve `operator.ask`: a Testing-only panel in which a person answers the agent's question. A mutation.
    public var operatorPrompts: Bool

    public init(
        scopes: [String] = ["current-screen"], routes: [AgentRoute] = [], fixtures: [String] = [],
        fixtureArguments: [String: ObjectSchema] = [:], actions: [AgentAction] = [], conditions: [AgentCondition] = [], lifecycle: [LifecycleCapability] = [],
        diagnosticCategories: [String] = [], commands: [AppCommand] = [], ui: UIAccess = [],
        invariants: [AgentInvariant] = [], experiments: [AgentExperiment] = [], operatorPrompts: Bool = false
    ) {
        self.ui = ui
        self.invariants = invariants
        self.experiments = experiments
        self.operatorPrompts = operatorPrompts
        self.scopes = scopes
        self.routes = routes
        self.fixtures = fixtures
        self.fixtureArguments = fixtureArguments
        self.actions = actions
        self.conditions = conditions
        self.lifecycle = lifecycle
        self.diagnosticCategories = diagnosticCategories
        self.commands = commands
    }

    /// Hides everything a read-only session must not advertise.
    func visible(allowMutations: Bool) -> AgentCatalog {
        guard !allowMutations else { return self }
        var visible = self
        visible.routes = []
        visible.fixtures = []
        visible.fixtureArguments = [:]
        visible.actions = []
        visible.lifecycle = lifecycle.filter { $0.kind != .scenario }
        visible.commands = commands.filter { !$0.mutating }
        visible.ui.subtract(.mutating)
        visible.experiments = experiments.filter(\.readOnly)
        visible.operatorPrompts = false
        return visible
    }

    /// App categories plus the built-in ones this catalog's features record.
    var allDiagnosticCategories: [String] {
        var categories = diagnosticCategories
        for (enabled, name) in [(!invariants.isEmpty, "invariant"), (!experiments.isEmpty, "experiment"), (operatorPrompts, "operator")]
        where enabled && !categories.contains(name) {
            categories.append(name)
        }
        return categories
    }
}
