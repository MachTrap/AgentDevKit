import AgentDevKitCore
import Foundation

/// Evaluates registered invariants after each recorded change, one run-loop turn later, and records each
/// transition to violated once. Lives on the main actor with the runtime and the adapter it reads.
@MainActor
final class InvariantEngine {
    static let maxViolations = 256

    private struct Entry {
        let invariant: AgentInvariant
        var holds = true
        var details: [String: JSONValue]?
        var evaluatedAt: UInt64 = 0
        var lastCost = 0
        var maxCost = 0
        var error: String?
        var openViolation: Int?
    }

    private var entries: [Entry]
    private let snapshot: @MainActor (String) throws -> ScreenState
    private var scheduled = false
    private var evaluatedRevision: UInt64?
    private(set) var violations: [InvariantViolation] = []
    private(set) var droppedViolations = false

    init(_ invariants: [AgentInvariant], snapshot: @escaping @MainActor (String) throws -> ScreenState) {
        entries = invariants.map { Entry(invariant: $0) }
        self.snapshot = snapshot
    }

    func schedule(_ runtime: AgentRuntime) {
        guard !scheduled, evaluatedRevision != runtime.revision else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self, weak runtime] in
            MainActor.assumeIsolated {
                guard let self, let runtime else { return }
                self.scheduled = false
                self.evaluate(runtime)
            }
        }
    }

    /// Evaluates now unless this revision was already evaluated.
    func evaluate(_ runtime: AgentRuntime) {
        let revision = runtime.revision
        guard evaluatedRevision != revision else { return }
        evaluatedRevision = revision
        var screens: [String: Result<ScreenState, any Error>] = [:]
        var changed = false
        for index in entries.indices {
            let invariant = entries[index].invariant
            let screen = screens[invariant.scope] ?? Result { try snapshot(invariant.scope) }
            screens[invariant.scope] = screen
            let clock = ContinuousClock()
            let started = clock.now
            let result: InvariantResult
            var problem: String?
            do { result = try invariant.evaluate(screen.get()) } catch {
                result = .violated(details: [:])
                problem = (error as? Failure).map { "\($0.code.rawValue): \($0.message)" } ?? "Evaluation failed."
            }
            let elapsed = started.duration(to: clock.now).components
            let micros = Int(elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
            entries[index].lastCost = micros
            entries[index].maxCost = max(entries[index].maxCost, micros)
            entries[index].evaluatedAt = revision
            entries[index].error = problem
            switch (entries[index].holds, result) {
            case (true, .violated(let details)):
                entries[index].holds = false
                entries[index].details = details
                if violations.count >= Self.maxViolations {
                    violations.removeFirst()
                    droppedViolations = true
                    for other in entries.indices { entries[other].openViolation = entries[other].openViolation.map { $0 - 1 } }
                }
                violations.append(InvariantViolation(id: invariant.id, scope: invariant.scope, revision: revision, details: details))
                entries[index].openViolation = violations.count - 1
                runtime.diagnose(DiagnosticRecord(severity: .warning, category: "invariant", code: invariant.id,
                                                  message: "Invariant \(invariant.id) violated at revision \(revision)."))
                changed = true
            case (false, .holds):
                entries[index].holds = true
                entries[index].details = nil
                if let open = entries[index].openViolation, violations.indices.contains(open) {
                    violations[open].resolvedAt = revision
                }
                entries[index].openViolation = nil
                changed = true
            case (false, .violated(let details)):
                entries[index].details = details
            case (true, .holds):
                break
            }
        }
        if changed { runtime.notifyChange() }
    }

    var states: [InvariantState] {
        entries.map { entry in
            InvariantState(id: entry.invariant.id, scope: entry.invariant.scope, holds: entry.holds && entry.error == nil,
                           evaluatedAt: entry.evaluatedAt, details: entry.holds ? nil : entry.details,
                           lastCostMicros: entry.lastCost, maxCostMicros: entry.maxCost,
                           overBudget: entry.lastCost > entry.invariant.budgetMicros, error: entry.error)
        }
    }

    /// Open violations by invariant ID, for `invariants.hold`.
    func failing(_ ids: [String]?) -> [String] {
        entries.filter { (!$0.holds || $0.error != nil) && (ids?.contains($0.invariant.id) ?? true) }.map(\.invariant.id)
    }

    var ids: [String] { entries.map(\.invariant.id) }

    func violations(since revision: UInt64) -> [InvariantViolation] {
        violations.filter { $0.revision > revision || ($0.resolvedAt ?? 0) > revision }
    }
}
