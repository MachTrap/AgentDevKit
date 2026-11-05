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
    private var open: [UUID: LifecycleToken] = [:]
    private var progress: [UUID: (completed: Int, total: Int?)] = [:]
    private var diagnostics: [DiagnosticRecord] = []
    private let diagnosticsCapacity: Int
    private var subscriptions: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Outcomes of tracked operations, kept after their journal events scroll out.
    private var tracked: [UUID: TrackedOutcome] = [:]
    private var trackedOrder: [UUID] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var presentingUI: Set<UUID> = []
    var invariantEngine: InvariantEngine?
    var operatorAnswers: [UUID: OperatorAnswer] = [:]
    var operatorOrder: [UUID] = []

    struct TrackedOutcome: Sendable {
        let outcome: LifecycleEvent.Outcome
        let code: String?
        let reason: String?
        let revision: UInt64
    }

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
        invariantEngine?.schedule(self)
    }

    // MARK: Tracked operations

    /// The longest a tracked body may run before its context deadline elapses.
    public static let trackedCeiling: Duration = .seconds(1_800)

    /// Runs `body` as a tracked operation owned by the runtime and returns `.accepted` at once.
    /// A `work` span named `name` opens now and closes with the body's outcome: completed, failed or cancelled.
    /// Wait for it with `operation.completed`; `operations.status` reports the outcome and failure reason.
    /// Set `presentsUI` when the body shows a panel, sheet or alert, so `operations.list` reports `awaitingUser`.
    @discardableResult
    public func track(
        _ name: String, scope: String, id: UUID = UUID(), parentId: UUID? = nil, correlationId: UUID? = nil,
        presentsUI: Bool = false, body: @escaping @MainActor () async throws -> Void
    ) -> ActionOutcome {
        let token = begin(.work, name: name, scope: scope, id: id, parentId: parentId, correlationId: correlationId)
        guard token != nil else {
            // The span could not open (bad name or ID, or the open-span limit); still run the work, but untracked.
            Task { try? await body() }
            return .completed
        }
        if presentsUI { presentingUI.insert(id) }
        tasks[id] = Task { [weak self] in
            var outcome = LifecycleEvent.Outcome.completed
            var failure: Failure?
            do { try await body() } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? Failure)?.code == .cancelled
                outcome = cancelled ? .cancelled : .failed
                failure = error as? Failure ?? Failure(cancelled ? .cancelled : .internalError,
                                                       cancelled ? "Operation cancelled." : "Operation failed.")
            }
            self?.finishTracked(id, token: token, outcome: outcome, failure: failure)
        }
        return .accepted(operationId: id)
    }

    /// Cancels a tracked operation started with `track`. Returns false when none is running with this ID.
    @discardableResult
    public func cancelTracked(_ id: UUID) -> Bool {
        guard let task = tasks[id] else { return false }
        task.cancel()
        return true
    }

    private func finishTracked(_ id: UUID, token: LifecycleToken?, outcome: LifecycleEvent.Outcome, failure: Failure?) {
        tasks[id] = nil
        presentingUI.remove(id)
        end(token, outcome: outcome)
        remember(id, TrackedOutcome(outcome: outcome, code: failure?.code.rawValue, reason: failure.map { String($0.message.prefix(256)) },
                                    revision: revision))
    }

    private func remember(_ id: UUID, _ outcome: TrackedOutcome) {
        if tracked[id] == nil {
            trackedOrder.append(id)
            if trackedOrder.count > 256 { tracked[trackedOrder.removeFirst()] = nil }
        }
        tracked[id] = outcome
        notifyChange()
    }

    func trackedOutcome(_ id: UUID) -> TrackedOutcome? { tracked[id] }

    /// Whether a modal panel, sheet, alert or operator question is on screen.
    var awaitingUser: Bool { UIInspection.modalSurfaceVisible() }

    // MARK: Lifecycle spans

    /// Opens a span. Returns nil when the name, scope or ID is invalid or the open-span limit is reached.
    @discardableResult
    public func begin(
        _ kind: LifecycleEvent.Kind, name: String, scope: String, id: UUID = UUID(), parentId: UUID? = nil,
        correlationId: UUID? = nil, changedFields: [String] = []
    ) -> LifecycleToken? {
        defer { notifyChange() }
        let token = journal.beginLifecycle(kind, name: name, scope: scope, id: id, parentId: parentId,
                                           correlationId: correlationId, changedFields: changedFields)
        if let token { open[token.id] = token }
        return token
    }

    /// Closes a span once. Duplicate, foreign and nil tokens have no effect.
    @discardableResult
    public func end(_ token: LifecycleToken?, outcome: LifecycleEvent.Outcome, changedFields: [String] = []) -> Bool {
        guard journal.endLifecycle(token, outcome: outcome, changedFields: changedFields) else { return false }
        if let token {
            open[token.id] = nil
            progress[token.id] = nil
        }
        notifyChange()
        return true
    }

    /// Closes the open span with this ID, such as an operation ID chosen at `begin`. Use it for
    /// concurrent work whose terminal callback knows the ID but not the token.
    @discardableResult
    public func end(id: UUID, outcome: LifecycleEvent.Outcome, changedFields: [String] = []) -> Bool {
        guard let token = open[id] else { return false }
        for (slot, held) in slots where held == token { slots[slot] = nil }
        return end(token, outcome: outcome, changedFields: changedFields)
    }

    /// Reports progress of an open span, such as items processed by a batch. Records a `work.progress`
    /// event so waits and observers see it. Returns false when no span with this ID is open.
    @discardableResult
    public func progress(id: UUID, completed: Int, total: Int? = nil) -> Bool {
        guard open[id] != nil, let span = journal.openSpans.first(where: { $0.id == id }) else { return false }
        progress[id] = (max(0, completed), total.map { max(0, $0) })
        record("\(span.kind.rawValue).progress", scope: span.scope, correlationId: span.correlationId, changedFields: ["progress"])
        return true
    }

    /// Open spans with their age and progress, oldest first.
    public func operations() -> [OperationInfo] {
        let now = ContinuousClock.now
        let awaiting = presentingUI.isEmpty ? false : awaitingUser
        return journal.openSpans.map { span in
            let age = span.started.duration(to: now).components
            return OperationInfo(id: span.id, kind: span.kind, name: span.name, scope: span.scope, parentId: span.parentId,
                                 correlationId: span.correlationId,
                                 ageMs: Int(age.seconds * 1_000 + age.attoseconds / 1_000_000_000_000_000),
                                 completed: progress[span.id]?.completed, total: progress[span.id]?.total,
                                 awaitingUser: presentingUI.contains(span.id) ? awaiting : nil)
        }
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

    // MARK: Operator answers

    func recordQuestion(_ id: UUID, question: String) {
        operatorOrder.append(id)
        if operatorOrder.count > 64 { operatorAnswers[operatorOrder.removeFirst()] = nil }
        operatorAnswers[id] = OperatorAnswer(operationId: id, status: .pending, question: question, answer: nil, notes: nil, revision: revision)
    }

    func recordAnswer(_ id: UUID, answer: String?, notes: String?) {
        guard let asked = operatorAnswers[id] else { return }
        operatorAnswers[id] = OperatorAnswer(operationId: id, status: answer == nil ? .unanswered : .answered, question: asked.question,
                                             answer: answer, notes: notes, revision: revision)
        notifyChange()
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
