import AgentDevKitCore
import Foundation

/// Scoped, app-owned state for one snapshot. The host adds the scope and journal revision.
public struct ScreenSnapshot: Sendable {
    public var screenId: String
    public var windowId: String
    public var ready: Bool
    public var fields: [String: JSONValue]
    public var operationId: UUID?
    public var blockers: [String]

    public init(screenId: String, windowId: String, ready: Bool, fields: [String: JSONValue] = [:],
                operationId: UUID? = nil, blockers: [String] = []) {
        self.screenId = screenId
        self.windowId = windowId
        self.ready = ready
        self.fields = fields
        self.operationId = operationId
        self.blockers = blockers
    }
}

/// Correlation for a presentation started by a bridge request.
public struct PresentationRequest: Sendable {
    public let requestId: UUID
    /// The enclosing `scenario.prepare` span, when the presentation is part of one.
    public let scenarioId: UUID?
}

/// The observed state of one presentation.
public enum Readiness: Sendable {
    case ready
    case pending(blockers: [String])
    case failed(Failure)
    /// Another presentation replaced this one.
    case superseded
}

/// The app's typed boundary. Implement it on a main-actor coordinator or a small wrapper
/// around existing models. Only `snapshot(scope:)` is required for a read-only bridge.
@MainActor
public protocol AgentAdapter: AnyObject, Sendable {
    associatedtype Destination = Never

    /// The presentation currently shown, if the adapter tracks presentations.
    /// `screen.ready` waits fail with CONFLICT when it changes during the wait.
    var currentPresentation: UUID? { get }

    /// Returns explicit, bounded fields for a registered scope. Never reflect arbitrary properties.
    func snapshot(scope: String) throws -> ScreenSnapshot

    /// Validates a route and its context without changing state. When `fixture` is set, validate
    /// against that fixture's data, because the fixture has not been applied yet.
    func resolve(route: String, context: RouteContext, fixture: String?) throws -> Destination

    /// Presents a resolved destination through the app's normal navigation model and returns
    /// a presentation ID that `readiness(of:)` understands.
    func present(_ destination: Destination, request: PresentationRequest) -> UUID

    /// Reports readiness from actual view appearance and tracked work gates.
    func readiness(of presentation: UUID) -> Readiness

    /// Replaces isolated test data with a registered fixture and returns summary fields.
    func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue]
}

extension AgentAdapter {
    public var currentPresentation: UUID? { nil }

    public func resolve(route: String, context: RouteContext, fixture: String?) throws -> Destination {
        throw Failure(.routeNotFound, "Route is not registered.")
    }

    public func readiness(of presentation: UUID) -> Readiness { .ready }

    public func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue] {
        throw Failure(.fixtureNotFound, "Fixture is not registered.")
    }
}

extension AgentAdapter where Destination == Never {
    public func present(_ destination: Never, request: PresentationRequest) -> UUID {}
}
