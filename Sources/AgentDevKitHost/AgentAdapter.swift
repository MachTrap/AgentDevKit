import AgentDevKitCore
import AppKit
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
    /// The resolved value `present(_:request:)` shows. Named so it never shadows an app's own `Destination` type.
    associatedtype NavigationTarget = Never

    /// The presentation currently shown, if the adapter tracks presentations.
    /// `screen.ready` waits fail with CONFLICT when it changes during the wait.
    var currentPresentation: UUID? { get }

    /// Returns explicit, bounded fields for a registered scope. Never reflect arbitrary properties.
    func snapshot(scope: String) throws -> ScreenSnapshot

    /// Validates a route and its context without changing state. When `fixture` is set, validate
    /// against that fixture's data, because the fixture has not been applied yet.
    func resolve(route: String, context: RouteContext, fixture: String?) throws -> NavigationTarget

    /// Presents a resolved destination through the app's normal navigation model and returns
    /// a presentation ID that `readiness(of:)` understands.
    func present(_ target: NavigationTarget, request: PresentationRequest) -> UUID

    /// Reports readiness from actual view appearance and tracked work gates.
    func readiness(of presentation: UUID) -> Readiness

    /// Replaces isolated test data with a registered fixture and returns summary fields.
    func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue]

    /// Loads a fixture with arguments validated against `AgentCatalog.fixtureArguments[id]`.
    /// The default ignores the arguments and calls `loadFixture(_:context:)`. It may be async, for apps whose
    /// storage is an actor; a synchronous implementation still satisfies it.
    func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue]

    /// Exact strings that must never leave the app, such as tokens and passwords from the app's own
    /// secret storage. The host replaces each one with `<redacted>` in every snapshot and fixture field.
    func secretValues() -> [String]

    /// The window that `ui.capture`, `ui.tree` and `ui.press` inspect. The default matches the
    /// identifier, an identifier prefix or the title, and with no ID picks the key or main window.
    func window(for windowId: String?) -> NSWindow?
}

extension AgentAdapter {
    public var currentPresentation: UUID? { nil }

    public func resolve(route: String, context: RouteContext, fixture: String?) throws -> NavigationTarget {
        throw Failure(.routeNotFound, "Route is not registered.")
    }

    public func readiness(of presentation: UUID) -> Readiness { .ready }

    public func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue] {
        throw Failure(.fixtureNotFound, "Fixture is not registered.")
    }

    public func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue] {
        try loadFixture(id, context: context)
    }

    public func secretValues() -> [String] { [] }

    public func window(for windowId: String?) -> NSWindow? { UIInspection.defaultWindow(windowId) }
}

extension ScreenSnapshot {
    /// A bounded preview of app text for a snapshot field: at most `maxBytes` UTF-8 bytes, cut on a
    /// character boundary, with "…" when shortened. Use it for bodies, logs and other unbounded text.
    public static func preview(_ text: String, maxBytes: Int = 512) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= max(0, maxBytes - 3) else { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }
}

extension AgentAdapter where NavigationTarget == Never {
    public func present(_ target: Never, request: PresentationRequest) -> UUID {}
}
