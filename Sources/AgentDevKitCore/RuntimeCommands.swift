import Foundation

extension AppCommands {
    public static let observe = Command<ObserveRequest, StateObservation>("state.observe")
    public static let wait = Command<WaitRequest, WaitState>("runtime.wait")
    public static let events = Command<EventsRequest, EventPage>("events.since")
    public static let diagnostics = Command<DiagnosticsRequest, [DiagnosticRecord]>("diagnostics.recent")
    public static let actions = Command<EmptyParameters, [ActionCapability]>("actions.list")
    public static let invoke = Command<ActionRequest, ScreenState>("actions.invoke")
}

public struct ObserveRequest: Codable, Sendable {
    public let scope: String
    public let sinceRevision: UInt64?
    public let limit: Int?

    public init(scope: String, sinceRevision: UInt64? = nil, limit: Int? = nil) {
        self.scope = scope
        self.sinceRevision = sinceRevision
        self.limit = limit
    }
}

public struct StateObservation: Codable, Sendable {
    public let screen: ScreenState
    public let delta: EventPage?
    public let resynced: Bool

    /// The caller supplies state captured on the actor that owns the journal.
    public init(screen: ScreenState, journal: RevisionJournal, request: ObserveRequest) throws {
        let limit = request.limit ?? 20
        guard (1...RevisionJournal.maxPageSize).contains(limit) else {
            throw Failure(.invalidParams, "Event page limit is out of range.")
        }
        guard screen.revision == journal.revision else {
            throw Failure(.internalError, "Snapshot and journal revisions differ.")
        }
        self.screen = screen
        guard let cursor = request.sinceRevision else {
            delta = nil
            resynced = false
            return
        }
        do {
            delta = try journal.since(cursor, limit: limit)
            resynced = false
        } catch let failure as Failure where failure.code == .staleRevision {
            delta = nil
            resynced = true
        }
    }
}

public struct WaitRequest: Codable, Sendable {
    public let condition: String
    public let scope: String
    public let operationId: UUID?
    public let field: String?
    public let value: JSONValue?

    public init(condition: String, scope: String, operationId: UUID? = nil, field: String? = nil, value: JSONValue? = nil) {
        self.condition = condition
        self.scope = scope
        self.operationId = operationId
        self.field = field
        self.value = value
    }
}

public struct WaitState: Codable, Sendable {
    public let satisfied: Bool
    public let screen: ScreenState
    public let lifecycle: LifecycleEvent?

    public init(screen: ScreenState, lifecycle: LifecycleEvent? = nil) {
        self.satisfied = true
        self.screen = screen
        self.lifecycle = lifecycle
    }
}

public struct EventsRequest: Codable, Sendable {
    public let revision: UInt64
    public let limit: Int?

    public init(revision: UInt64, limit: Int? = nil) {
        self.revision = revision
        self.limit = limit
    }
}

public struct RevisionEvent: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let type: String
    public let scope: String
    public let timestamp: Date
    public let correlationId: UUID?
    public let changedFields: [String]
    public let lifecycle: LifecycleEvent?

    public init(revision: UInt64, type: String, scope: String, timestamp: Date = .now,
                correlationId: UUID? = nil, changedFields: [String], lifecycle: LifecycleEvent? = nil) {
        self.revision = revision
        self.type = type
        self.scope = scope
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.changedFields = changedFields
        self.lifecycle = lifecycle
    }
}

public struct EventPage: Codable, Sendable {
    public let events: [RevisionEvent]
    public let nextRevision: UInt64
    public let latestRevision: UInt64
    public let hasMore: Bool
}

/// Keep this value on the same actor as the state it describes so revision
/// checks, snapshots and event writes can share one isolation boundary.
public struct RevisionJournal: Sendable {
    private var buffer: [RevisionEvent?]
    var lifecycles: [UUID: ActiveLifecycle] = [:]
    public private(set) var revision: UInt64 = 0
    public static let maxPageSize = 100

    public init(capacity: Int = 500) {
        precondition(capacity > 0)
        buffer = Array(repeating: nil, count: capacity)
    }

    public mutating func append(type: String, scope: String, correlationId: UUID? = nil, changedFields: [String], lifecycle: LifecycleEvent? = nil) {
        revision += 1
        buffer[index(revision)] = RevisionEvent(
            revision: revision, type: type, scope: scope, correlationId: correlationId, changedFields: changedFields, lifecycle: lifecycle
        )
    }

    public func since(_ cursor: UInt64, limit: Int = Self.maxPageSize) throws -> EventPage {
        guard cursor <= revision, (1...Self.maxPageSize).contains(limit) else {
            throw Failure(.invalidParams, "Cursor or page limit is out of range.")
        }
        guard revision - cursor <= UInt64(buffer.count) else {
            throw Failure(.staleRevision, "The cursor fell behind retained events.",
                          details: ["resyncRequired": "true", "latestRevision": String(revision)])
        }
        let count = min(Int(revision - cursor), limit)
        let events = (0..<count).compactMap { offset in buffer[index(cursor + UInt64(offset) + 1)] }
        let next = cursor + UInt64(count)
        return EventPage(events: events, nextRevision: next, latestRevision: revision, hasMore: next < revision)
    }

    /// Reads a retained terminal event by its span ID, even after navigation moved on.
    public func terminalLifecycle(_ id: UUID) -> LifecycleEvent? {
        let count = min(revision, UInt64(buffer.count))
        for offset in 0..<count {
            if let span = buffer[index(revision - offset)]?.lifecycle, span.id == id, span.phase == .ended {
                return span
            }
        }
        return nil
    }

    private func index(_ revision: UInt64) -> Int {
        Int((revision - 1) % UInt64(buffer.count))
    }
}

public struct DiagnosticsRequest: Codable, Sendable {
    public let severity: DiagnosticRecord.Severity?
    public let category: String?
    public let limit: Int?

    public init(severity: DiagnosticRecord.Severity? = nil, category: String? = nil, limit: Int? = nil) {
        self.severity = severity
        self.category = category
        self.limit = limit
    }
}

public struct DiagnosticRecord: Codable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }

    public let severity: Severity
    public let category: String
    public let code: String
    public let message: String
    public let timestamp: Date
    public let correlationId: UUID?

    public init(severity: Severity, category: String, code: String, message: String,
                timestamp: Date = .now, correlationId: UUID? = nil) {
        self.severity = severity
        self.category = category
        self.code = code
        self.message = message
        self.timestamp = timestamp
        self.correlationId = correlationId
    }
}

public struct ActionCapability: Codable, Sendable, Equatable {
    public let id: String
    public let scope: String
    public let enabled: Bool
    public let inputSchema: [String: JSONValue]
    public let interaction: String

    public init(id: String, scope: String, enabled: Bool, inputSchema: [String: JSONValue]) {
        self.id = id
        self.scope = scope
        self.enabled = enabled
        self.inputSchema = inputSchema
        self.interaction = "semantic"
    }

    private enum CodingKeys: String, CodingKey { case id, scope, enabled, inputSchema, interaction }
}

public struct ActionRequest: Codable, Sendable {
    public let actionId: String
    public let arguments: [String: JSONValue]
    public let expectedRevision: UInt64?

    public init(actionId: String, arguments: [String: JSONValue], expectedRevision: UInt64? = nil) {
        self.actionId = actionId
        self.arguments = arguments
        self.expectedRevision = expectedRevision
    }
}
