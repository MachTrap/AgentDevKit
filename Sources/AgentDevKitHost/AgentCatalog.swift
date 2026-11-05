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
    let enabled: @MainActor @Sendable () -> Bool
    let run: @MainActor @Sendable ([String: JSONValue], CommandContext) async throws -> ActionOutcome

    public init<Input: Decodable>(
        _ id: String, scope: String, input: ObjectSchema, as type: Input.Type,
        enabled: @escaping @MainActor @Sendable () -> Bool = { true },
        run: @escaping @MainActor @Sendable (Input, CommandContext) async throws -> ActionOutcome
    ) {
        self.id = id
        self.scope = scope
        self.input = input
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

    public init(
        scopes: [String] = ["current-screen"], routes: [AgentRoute] = [], fixtures: [String] = [],
        fixtureArguments: [String: ObjectSchema] = [:], actions: [AgentAction] = [], conditions: [AgentCondition] = [], lifecycle: [LifecycleCapability] = [],
        diagnosticCategories: [String] = [], commands: [AppCommand] = [], ui: UIAccess = []
    ) {
        self.ui = ui
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
        visible.ui.remove(.press)
        return visible
    }
}
