import AgentDevKitCore
import Foundation
import os

/// Bounded memory of mutating requests, so a caller whose connection dropped can ask whether its request applied.
/// Keyed by the opaque request UUIDs of this session; entries expire after `retention`.
final class RequestLedger: Sendable {
    struct Entry: Sendable {
        let requestId: UUID
        let method: String
        let created: ContinuousClock.Instant
        var state: OperationStatus.State
        var operationId: UUID?
        var revision: UInt64?
        var code: String?
        var reason: String?
        var result: JSONValue?
        var details: [String: JSONValue]?
    }

    private struct Storage {
        var entries: [UUID: Entry] = [:]
        var order: [UUID] = []
        var byOperation: [UUID: UUID] = [:]
        var onChange: (@Sendable () -> Void)?
    }

    static let capacity = 256
    static let retention: Duration = .seconds(600)
    static let maxResultBytes = 65_536

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// Called after an entry finishes, so pending waits on `operation.completed` re-evaluate.
    func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        storage.withLock { $0.onChange = handler }
    }

    func begin(_ requestId: UUID, method: String) {
        storage.withLock { state in
            Self.expire(&state)
            if state.entries[requestId] == nil {
                if state.order.count >= Self.capacity, let oldest = state.order.first {
                    state.order.removeFirst()
                    if let operation = state.entries.removeValue(forKey: oldest)?.operationId { state.byOperation[operation] = nil }
                }
                state.order.append(requestId)
            }
            state.entries[requestId] = Entry(requestId: requestId, method: method, created: .now, state: .pending)
        }
    }

    /// The request returned `accepted`; its work continues under `operationId`.
    func accepted(_ requestId: UUID, operationId: UUID) {
        storage.withLock { state in
            state.entries[requestId]?.operationId = operationId
            state.byOperation[operationId] = requestId
        }
    }

    /// Records the final response envelope. An `accepted` envelope keeps the entry pending.
    func finish(_ requestId: UUID, response: Data) {
        guard let envelope = try? JSONDecoder().decode(Response<JSONValue>.self, from: response) else {
            return fail(requestId, Failure(.internalError, "Response could not be recorded."))
        }
        if let error = envelope.error { return fail(requestId, error) }
        let result = envelope.result
        let handler = storage.withLock { state -> (@Sendable () -> Void)? in
            guard var entry = state.entries[requestId] else { return nil }
            entry.revision = Self.revision(in: result)
            if let operation = Self.operationId(in: result), envelope.status == .accepted {
                entry.operationId = operation
                state.byOperation[operation] = requestId
            }
            entry.state = envelope.status == .accepted ? .pending : .completed
            entry.result = response.count <= Self.maxResultBytes ? result : nil
            state.entries[requestId] = entry
            return state.onChange
        }
        handler?()
    }

    func fail(_ requestId: UUID, _ failure: Failure, revision: UInt64? = nil) {
        let handler = storage.withLock { state -> (@Sendable () -> Void)? in
            guard state.entries[requestId] != nil else { return nil }
            state.entries[requestId]?.state = failure.code == .cancelled ? .cancelled : .failed
            state.entries[requestId]?.code = failure.code.rawValue
            state.entries[requestId]?.reason = String(failure.message.prefix(256))
            if let details = failure.details, (try? JSONEncoder().encode(details).count) ?? .max <= 4_096 {
                state.entries[requestId]?.details = details
            }
            if let revision { state.entries[requestId]?.revision = revision }
            return state.onChange
        }
        handler?()
    }

    func entry(request requestId: UUID) -> Entry? {
        storage.withLock { state in
            Self.expire(&state)
            return state.entries[requestId]
        }
    }

    func entry(operation operationId: UUID) -> Entry? {
        storage.withLock { state in
            Self.expire(&state)
            return state.byOperation[operationId].flatMap { state.entries[$0] } ?? state.entries[operationId]
        }
    }

    func removeAll() {
        storage.withLock { state in
            state.entries.removeAll()
            state.order.removeAll()
            state.byOperation.removeAll()
        }
    }

    private static func expire(_ state: inout Storage) {
        let cutoff = ContinuousClock.now - retention
        while let oldest = state.order.first, let entry = state.entries[oldest], entry.created < cutoff, entry.state != .pending {
            state.order.removeFirst()
            state.entries[oldest] = nil
            if let operation = entry.operationId { state.byOperation[operation] = nil }
        }
    }

    /// The revision a result reports: its own, or that of its screen or fixture.
    static func revision(in result: JSONValue?) -> UInt64? {
        let object = result?.objectValue
        let value = object?["revision"]?.integerValue
            ?? object?["screen"]?.objectValue?["revision"]?.integerValue
            ?? object?["fixture"]?.objectValue?["revision"]?.integerValue
        return value.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    static func operationId(in result: JSONValue?) -> UUID? {
        result?.objectValue?["operationId"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
}

/// Resumes a continuation once, from whichever racer finishes first.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ value: Value) {
        let pending = continuation.withLock { stored -> CheckedContinuation<Value, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
