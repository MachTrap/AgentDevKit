import Foundation

// MARK: Invariants

public enum InvariantCommands {
    /// Lists registered invariants with their current result and evaluation cost.
    public static let list = Command<EmptyParameters, InvariantReport>("invariants.list")
}

/// One recorded transition of an invariant from holding to violated.
public struct InvariantViolation: Codable, Sendable, Equatable {
    public let id: String
    public let scope: String
    /// The journal revision whose state violated the invariant.
    public let revision: UInt64
    /// App-defined, bounded facts about the violation. Never user content or secrets.
    public let details: [String: JSONValue]
    public let timestamp: Date
    /// The revision at which the invariant held again, if it did.
    public var resolvedAt: UInt64?

    public init(id: String, scope: String, revision: UInt64, details: [String: JSONValue], timestamp: Date = .now, resolvedAt: UInt64? = nil) {
        self.id = id
        self.scope = scope
        self.revision = revision
        self.details = details
        self.timestamp = timestamp
        self.resolvedAt = resolvedAt
    }
}

public struct InvariantState: Codable, Sendable, Equatable {
    public let id: String
    public let scope: String
    public let holds: Bool
    /// The revision of the latest evaluation.
    public let evaluatedAt: UInt64
    /// Details of the open violation, when `holds` is false.
    public let details: [String: JSONValue]?
    /// Cost of the latest evaluation, in microseconds.
    public let lastCostMicros: Int
    /// The slowest evaluation so far, in microseconds.
    public let maxCostMicros: Int
    /// The latest evaluation exceeded the invariant's budget.
    public let overBudget: Bool
    /// The evaluation threw. `holds` is reported as false.
    public let error: String?

    public init(id: String, scope: String, holds: Bool, evaluatedAt: UInt64, details: [String: JSONValue]?, lastCostMicros: Int,
                maxCostMicros: Int, overBudget: Bool, error: String? = nil) {
        self.id = id
        self.scope = scope
        self.holds = holds
        self.evaluatedAt = evaluatedAt
        self.details = details
        self.lastCostMicros = lastCostMicros
        self.maxCostMicros = maxCostMicros
        self.overBudget = overBudget
        self.error = error
    }
}

public struct InvariantReport: Codable, Sendable {
    public let revision: UInt64
    public let invariants: [InvariantState]
    /// Retained violations, oldest first.
    public let violations: [InvariantViolation]
    public let truncated: Bool

    public init(revision: UInt64, invariants: [InvariantState], violations: [InvariantViolation], truncated: Bool) {
        self.revision = revision
        self.invariants = invariants
        self.violations = violations
        self.truncated = truncated
    }
}

// MARK: Operator prompts

public enum OperatorCommands {
    /// Shows a question in a Testing-only panel in the app. Returns at once with an operation ID.
    public static let ask = Command<OperatorQuestion, OperatorTicket>("operator.ask", mutating: true)
    /// Reads the answer to an earlier question.
    public static let answer = Command<OperatorAnswerRequest, OperatorAnswer>("operator.answer")
}

public struct OperatorQuestion: Codable, Sendable {
    public let question: String
    /// Button titles, 1…6. Defaults to OK.
    public let options: [String]?
    /// Show a notes field the person may fill in.
    public let allowNotes: Bool?
    /// How long the panel stays up before the answer becomes `unanswered`. 1 s…30 min, default 5 min.
    public let answerTimeoutMs: Int?

    public init(question: String, options: [String]? = nil, allowNotes: Bool? = nil, answerTimeoutMs: Int? = nil) {
        self.question = question
        self.options = options
        self.allowNotes = allowNotes
        self.answerTimeoutMs = answerTimeoutMs
    }
}

public struct OperatorTicket: Codable, Sendable {
    public let operationId: UUID
    public let revision: UInt64
    public init(operationId: UUID, revision: UInt64) {
        self.operationId = operationId
        self.revision = revision
    }
}

public struct OperatorAnswerRequest: Codable, Sendable {
    public let operationId: UUID
    public init(operationId: UUID) { self.operationId = operationId }
}

public struct OperatorAnswer: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, answered, unanswered, cancelled }
    public let operationId: UUID
    public let status: Status
    public let question: String
    public let answer: String?
    public let notes: String?
    public let revision: UInt64

    public init(operationId: UUID, status: Status, question: String, answer: String?, notes: String?, revision: UInt64) {
        self.operationId = operationId
        self.status = status
        self.question = question
        self.answer = answer
        self.notes = notes
        self.revision = revision
    }
}

// MARK: Experiments

public enum ExperimentCommands {
    /// Runs a registered investigation probe. Probes that are not read-only need a mutation session.
    public static let run = Command<ExperimentRequest, ExperimentResult>("experiments.run")
}

public struct ExperimentRequest: Codable, Sendable {
    public let experimentId: String
    public let arguments: [String: JSONValue]?
    public init(experimentId: String, arguments: [String: JSONValue]? = nil) {
        self.experimentId = experimentId
        self.arguments = arguments
    }
}

public struct ExperimentResult: Codable, Sendable {
    public let experimentId: String
    public let fields: [String: JSONValue]
    public let durationMs: Int
    public let revision: UInt64
    public init(experimentId: String, fields: [String: JSONValue], durationMs: Int, revision: UInt64) {
        self.experimentId = experimentId
        self.fields = fields
        self.durationMs = durationMs
        self.revision = revision
    }
}

// MARK: Privacy probes

public enum PrivacyCommands {
    /// Reports what the app's own process can observe about its privacy grants, without reading TCC databases
    /// and without triggering a prompt.
    public static let status = Command<EmptyParameters, PrivacyStatus>("privacy.status")
}

public struct PrivacyStatus: Codable, Sendable, Equatable {
    public enum Observation: String, Codable, Sendable { case granted, denied, unknown }
    public let bundleId: String
    public let sandboxed: Bool
    /// Whether a directory that requires Full Disk Access could be listed.
    public let fullDiskAccess: Observation
    public let accessibility: Observation
    public let screenRecording: Observation
    /// How each value was observed.
    public let probes: [String: String]

    public init(bundleId: String, sandboxed: Bool, fullDiskAccess: Observation, accessibility: Observation,
                screenRecording: Observation, probes: [String: String]) {
        self.bundleId = bundleId
        self.sandboxed = sandboxed
        self.fullDiskAccess = fullDiskAccess
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.probes = probes
    }
}
