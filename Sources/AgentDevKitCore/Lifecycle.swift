import Foundation

/// A stable trace envelope. App adapters supply registered names and scopes.
public struct LifecycleEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case screen, work, scenario }
    public enum Phase: String, Codable, Sendable { case began, ended }
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled, superseded, accepted }

    public let id: UUID
    public let parentId: UUID?
    public let kind: Kind
    public let name: String
    public let phase: Phase
    public let outcome: Outcome?
    public let durationMs: Int?
}

public struct LifecycleCapability: Codable, Sendable, Equatable {
    public let kind: LifecycleEvent.Kind
    public let name: String

    public init(kind: LifecycleEvent.Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct LifecycleToken: Hashable, Sendable {
    public let id: UUID
    // A token from another journal, or an earlier use of the same ID, cannot close this span.
    fileprivate let nonce = UUID()

    fileprivate init(id: UUID) { self.id = id }
}

struct ActiveLifecycle: Sendable {
    let token: LifecycleToken
    let parentId: UUID?
    let kind: LifecycleEvent.Kind
    let name: String
    let scope: String
    let correlationId: UUID?
    let started: ContinuousClock.Instant
}

extension RevisionJournal {
    /// Call on the actor that owns this journal and the corresponding app state.
    /// Names and scopes are static app identifiers. Pass no user content.
    @discardableResult
    public mutating func beginLifecycle(
        _ kind: LifecycleEvent.Kind, name: String, scope: String,
        id: UUID = UUID(), parentId: UUID? = nil, correlationId: UUID? = nil,
        changedFields: [String] = []
    ) -> LifecycleToken? {
        guard lifecycles.count < 128, lifecycles[id] == nil, id != parentId,
              (1...128).contains(name.utf8.count), (1...128).contains(scope.utf8.count) else { return nil }
        let span = ActiveLifecycle(token: LifecycleToken(id: id), parentId: parentId, kind: kind,
                                   name: name, scope: scope, correlationId: correlationId, started: .now)
        lifecycles[id] = span
        record(span, phase: .began, changedFields: changedFields)
        return span.token
    }

    /// Closes the matching span once. A duplicate or unknown completion has no effect.
    @discardableResult
    public mutating func endLifecycle(
        _ token: LifecycleToken?, outcome: LifecycleEvent.Outcome, changedFields: [String] = []
    ) -> Bool {
        guard let token, let span = lifecycles[token.id], span.token == token else { return false }
        lifecycles[token.id] = nil
        record(span, phase: .ended, outcome: outcome, changedFields: changedFields)
        return true
    }

    private mutating func record(
        _ span: ActiveLifecycle, phase: LifecycleEvent.Phase,
        outcome: LifecycleEvent.Outcome? = nil, changedFields: [String]
    ) {
        let type = switch (span.kind, phase) {
        case (.screen, .began): "screen.opened"
        case (.screen, .ended): "screen.closed"
        case (.work, .began): "work.started"
        case (.work, .ended): "work.finished"
        case (.scenario, .began): "scenario.started"
        case (.scenario, .ended): "scenario.finished"
        }
        let elapsed = span.started.duration(to: .now).components
        let durationMs = phase == .ended ? Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000) : nil
        append(type: type, scope: span.scope, correlationId: span.correlationId, changedFields: changedFields,
               lifecycle: LifecycleEvent(id: span.token.id, parentId: span.parentId, kind: span.kind,
                                         name: span.name, phase: phase, outcome: outcome, durationMs: durationMs))
    }
}
