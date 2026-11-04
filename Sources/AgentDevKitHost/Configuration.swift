import AgentDevKitCore
import Foundation

/// Bounded host settings. Values outside a limit's range are clamped to it.
public struct AgentHostConfiguration: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Authenticated requests accepted per monotonic second.
        public var requestsPerSecond: Int
        /// Unauthenticated or malformed requests accepted per monotonic second before RATE_LIMITED.
        public var rejectedRequestsPerSecond: Int
        /// Concurrent connections served by the listener.
        public var maxConnections: Int
        /// Request frame size, including envelope and parameters.
        public var maxRequestBytes: Int
        /// Encoded response size. Larger results return RESPONSE_TOO_LARGE.
        public var maxResponseBytes: Int
        /// Time allowed between accepting a connection and receiving its full request frame.
        public var requestReadTimeoutMs: Int
        /// Retained request IDs. A repeated ID with identical method and params replays the cached response.
        public var retainedRequestIds: Int
        /// Total bytes of cached responses kept for replay.
        public var replayCacheBytes: Int
        /// Longest request deadline a client may ask for.
        public var maxTimeoutMs: Int
        /// Time reserved at the end of a deadline so a wait can still encode and send its response.
        public var waitMarginMs: Int

        public init(
            requestsPerSecond: Int = 30, rejectedRequestsPerSecond: Int = 10, maxConnections: Int = 4,
            maxRequestBytes: Int = Wire.maxRequestBytes, maxResponseBytes: Int = Wire.maxFrameBytes,
            requestReadTimeoutMs: Int = 500, retainedRequestIds: Int = 256, replayCacheBytes: Int = 2_097_152,
            maxTimeoutMs: Int = Wire.maxTimeoutMs, waitMarginMs: Int = 120
        ) {
            self.replayCacheBytes = replayCacheBytes
            self.maxTimeoutMs = maxTimeoutMs
            self.waitMarginMs = waitMarginMs
            self.requestsPerSecond = requestsPerSecond
            self.rejectedRequestsPerSecond = rejectedRequestsPerSecond
            self.maxConnections = maxConnections
            self.maxRequestBytes = maxRequestBytes
            self.maxResponseBytes = maxResponseBytes
            self.requestReadTimeoutMs = requestReadTimeoutMs
            self.retainedRequestIds = retainedRequestIds
        }

        /// Limits with every value clamped to its supported range.
        public var clamped: Limits {
            Limits(
                requestsPerSecond: requestsPerSecond.clamped(1...200),
                rejectedRequestsPerSecond: rejectedRequestsPerSecond.clamped(1...50),
                maxConnections: maxConnections.clamped(1...16),
                maxRequestBytes: maxRequestBytes.clamped(512...65_536),
                maxResponseBytes: maxResponseBytes.clamped(1_024...Wire.maxFrameBytes),
                requestReadTimeoutMs: requestReadTimeoutMs.clamped(50...Wire.maxTimeoutMs),
                retainedRequestIds: retainedRequestIds.clamped(16...4_096),
                replayCacheBytes: replayCacheBytes.clamped(0...16_777_216),
                maxTimeoutMs: maxTimeoutMs.clamped(500...Wire.timeoutCeilingMs),
                waitMarginMs: waitMarginMs.clamped(20...400)
            )
        }
    }

    /// The app identity published in the session descriptor.
    public enum Identity: Sendable {
        /// Read the bundle identifier and hash the executable of `Bundle.main`.
        case mainBundle
        /// A fixed identity for tests and command-line hosts that have no app bundle.
        case fixed(bundleId: String, buildFingerprint: String)
    }

    public var limits: Limits
    public var identity: Identity
    /// Maps an app error that is not a `Failure`. Return nil to report INTERNAL_ERROR with only the error type name.
    public var onError: (@Sendable (any Error) -> Failure?)?

    public init(limits: Limits = Limits(), identity: Identity = .mainBundle, onError: (@Sendable (any Error) -> Failure?)? = nil) {
        self.limits = limits
        self.identity = identity
        self.onError = onError
    }
}

/// A typed reason the host could not start a session.
public enum AgentHostStartError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case identityUnavailable
    case appGroupUnavailable
    case pairingFolderInvalid
    case socketPathTooLong
    case listenerFailed
    case cancelled

    public var description: String {
        switch self {
        case .alreadyRunning: "A bridge is already running or stopping."
        case .identityUnavailable: "Application identity unavailable."
        case .appGroupUnavailable: "App Group unavailable. Check the signing team and App Group entitlement."
        case .pairingFolderInvalid: "Pairing folder unavailable. Select an accessible folder owned by you with mode 0700."
        case .socketPathTooLong: "The session socket path exceeds the 104-byte Unix socket limit. Use a shorter App Group or bundle identifier."
        case .listenerFailed: "The bridge listener could not start."
        case .cancelled: "Bridge startup was cancelled."
        }
    }
}

public enum AgentHostState: Sendable, Equatable {
    case stopped
    case starting
    case running(SessionIdentity)
    case stopping
    case failed(AgentHostStartError)
}

extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
