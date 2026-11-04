import AgentDevKitCore
import Foundation

/// A named place for at most one open span, such as the current screen or document load.
public struct SpanSlot: Hashable, Sendable, ExpressibleByStringLiteral {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { name = value }
}

/// Owns the revision journal, open spans, diagnostics and change notifications for
/// app state that lives on the main actor. Snapshots and revisions are read in the
/// same main-actor turn, so a snapshot's revision always matches the journal.
@MainActor
public final class AgentRuntime {
    public private(set) var journal: RevisionJournal
    private var slots: [SpanSlot: LifecycleToken] = [:]
    private var diagnostics: [DiagnosticRecord] = []
    private let diagnosticsCapacity: Int
    private var subscriptions: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(journalCapacity: Int = 500, diagnosticsCapacity: Int = 64) {
        journal = RevisionJournal(capacity: journalCapacity.clamped(16...10_000))
        self.diagnosticsCapacity = diagnosticsCapacity.clamped(1...1_000)
    }

    public var revision: UInt64 { journal.revision }

    /// Appends a change event. Use static type names and field names, never user content.
    public func record(_ type: String, scope: String, correlationId: UUID? = nil, changedFields: [String] = []) {
        journal.append(type: type, scope: scope, correlationId: correlationId, changedFields: changedFields)
        notifyChange()
    }

    /// Wakes pending waits after app state changed without a journal event.
    public func notifyChange() {
        for subscription in subscriptions.values { subscription.yield(()) }
    }

    // MARK: Lifecycle spans

    /// Opens a span. Returns nil when the name, scope or ID is invalid or the open-span limit is reached.
    @discardableResult
    public func begin(
        _ kind: LifecycleEvent.Kind, name: String, scope: String, id: UUID = UUID(), parentId: UUID? = nil,
        correlationId: UUID? = nil, changedFields: [String] = []
    ) -> LifecycleToken? {
        defer { notifyChange() }
        return journal.beginLifecycle(kind, name: name, scope: scope, id: id, parentId: parentId,
                                      correlationId: correlationId, changedFields: changedFields)
    }

    /// Closes a span once. Duplicate, foreign and nil tokens have no effect.
    @discardableResult
    public func end(_ token: LifecycleToken?, outcome: LifecycleEvent.Outcome, changedFields: [String] = []) -> Bool {
        guard journal.endLifecycle(token, outcome: outcome, changedFields: changedFields) else { return false }
        notifyChange()
        return true
    }

    /// Opens a span in a slot. A span still open in that slot ends as `superseded` first.
    @discardableResult
    public func begin(
        _ slot: SpanSlot, _ kind: LifecycleEvent.Kind, name: String, scope: String, id: UUID = UUID(),
        parentId: UUID? = nil, correlationId: UUID? = nil, changedFields: [String] = []
    ) -> LifecycleToken? {
        if let previous = slots.removeValue(forKey: slot) { end(previous, outcome: .superseded) }
        let token = begin(kind, name: name, scope: scope, id: id, parentId: parentId,
                          correlationId: correlationId, changedFields: changedFields)
        slots[slot] = token
        return token
    }

    /// Closes the span in a slot, if any.
    @discardableResult
    public func end(_ slot: SpanSlot, outcome: LifecycleEvent.Outcome, changedFields: [String] = []) -> Bool {
        end(slots.removeValue(forKey: slot), outcome: outcome, changedFields: changedFields)
    }

    /// The span currently open in a slot.
    public func span(_ slot: SpanSlot) -> LifecycleToken? { slots[slot] }

    /// Runs `body` inside a span. A thrown `CancellationError` or CANCELLED failure ends the span
    /// as `cancelled`, any other error as `failed`, and a result for which `accepted` is true as `accepted`.
    public func withLifecycle<Value>(
        _ kind: LifecycleEvent.Kind, name: String, scope: String, id: UUID = UUID(), parentId: UUID? = nil,
        correlationId: UUID? = nil, accepted: (Value) -> Bool = { _ in false },
        _ body: (LifecycleToken?) async throws -> Value
    ) async throws -> Value {
        let token = begin(kind, name: name, scope: scope, id: id, parentId: parentId, correlationId: correlationId)
        do {
            let value = try await body(token)
            end(token, outcome: accepted(value) ? .accepted : .completed)
            return value
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? Failure)?.code == .cancelled
            end(token, outcome: cancelled ? .cancelled : .failed)
            throw error
        }
    }

    // MARK: Diagnostics

    /// Retains a bounded diagnostic. Messages must be fixed summaries without user data or secrets.
    public func diagnose(_ record: DiagnosticRecord) {
        if diagnostics.count >= diagnosticsCapacity { diagnostics.removeFirst() }
        diagnostics.append(record)
        notifyChange()
    }

    func recentDiagnostics(_ request: DiagnosticsRequest, categories: [String]) throws -> [DiagnosticRecord] {
        let limit = request.limit ?? 10
        guard (1...50).contains(limit) else {
            throw Failure(.invalidParams, "Diagnostic limit is out of range.", details: ["field": "limit"])
        }
        if let category = request.category, !categories.contains(category) {
            throw Failure(.invalidParams, "Diagnostic category is not registered.", details: ["field": "category"])
        }
        return Array(diagnostics.reversed().lazy.filter { record in
            (request.severity != .error || record.severity == .error) &&
                (request.category == nil || record.category == request.category)
        }.prefix(limit))
    }

    // MARK: Waiting

    /// Re-evaluates on every change until a value is produced or the deadline passes.
    /// Returns nil on deadline. Cancellation throws CANCELLED.
    func wait<Value: Sendable>(until deadline: ContinuousClock.Instant, evaluate: () throws -> Value?) async throws -> Value? {
        let id = UUID()
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        subscriptions[id] = continuation
        defer {
            subscriptions[id] = nil
            continuation.finish()
        }
        return try await waitForChange(until: deadline, changes: changes, evaluate: evaluate)
    }
}

/// Observes state changes without polling and releases the subscription on every exit.
/// Returns nil when the deadline passes before `evaluate` produces a value.
@MainActor
func waitForChange<Value: Sendable>(
    until deadline: ContinuousClock.Instant, changes: AsyncStream<Void>, evaluate: () throws -> Value?
) async throws -> Value? {
    if let result = try evaluate() { return result }
    guard ContinuousClock.now < deadline else { return nil }
    let (ticks, timer) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in changes { timer.yield(false) }
        }
        group.addTask {
            guard (try? await ContinuousClock().sleep(until: deadline)) != nil else { return }
            timer.yield(true)
            timer.finish()
        }
        defer {
            group.cancelAll()
            timer.finish()
        }
        for await timedOut in ticks {
            if let result = try evaluate() { return result }
            if timedOut || ContinuousClock.now >= deadline { return nil }
        }
        throw Failure(.cancelled, "Request cancelled.")
    }
}
