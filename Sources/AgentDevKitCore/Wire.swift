import Foundation

public enum Wire {
    public static let version = "agentdevkit/1"
    public static let maxFrameBytes = 1_048_576
    public static let maxRequestBytes = 4_096
    public static let maxTimeoutMs = 2_000
}

public enum SystemMethod: String, Codable, Sendable, CaseIterable {
    case hello = "system.hello"
    case capabilities = "system.capabilities"
}

/// The first decoding pass deliberately ignores command parameters.
public struct RequestHeader: Decodable, Sendable {
    public let version: String
    public let requestId: UUID
    public let sessionId: UUID
    public let auth: String
    public let method: String
    public let timeoutMs: Int

    private enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case requestId, sessionId, auth, method, timeoutMs
    }
}

public struct Request<Parameters: Codable & Sendable>: Codable, Sendable {
    public let version: String
    public let requestId: UUID
    public let sessionId: UUID
    public let auth: String
    public let method: String
    public let params: Parameters
    public let timeoutMs: Int

    public init(
        requestId: UUID = UUID(), sessionId: UUID, auth: String,
        method: String, params: Parameters, timeoutMs: Int = Wire.maxTimeoutMs
    ) {
        self.version = Wire.version
        self.requestId = requestId
        self.sessionId = sessionId
        self.auth = auth
        self.method = method
        self.params = params
        self.timeoutMs = timeoutMs
    }

    public init(
        requestId: UUID = UUID(), sessionId: UUID, auth: String,
        method: SystemMethod, params: Parameters, timeoutMs: Int = Wire.maxTimeoutMs
    ) {
        self.init(requestId: requestId, sessionId: sessionId, auth: auth,
                  method: method.rawValue, params: params, timeoutMs: timeoutMs)
    }

    private enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case requestId, sessionId, auth, method, params, timeoutMs
    }
}

/// A strict empty object. A closed CodingKeys enum would silently ignore unknown keys.
public struct EmptyParameters: Codable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        let object = try decoder.container(keyedBy: Key.self)
        guard object.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Expected an empty object."
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: Key.self)
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

public struct Failure: Error, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case authRequired = "AUTH_REQUIRED"
        case permissionDenied = "PERMISSION_DENIED"
        case unsupportedVersion = "UNSUPPORTED_VERSION"
        case unknownMethod = "UNKNOWN_METHOD"
        case invalidParams = "INVALID_PARAMS"
        case routeNotFound = "ROUTE_NOT_FOUND"
        case fixtureNotFound = "FIXTURE_NOT_FOUND"
        case notReady = "NOT_READY"
        case cancelled = "CANCELLED"
        case staleRevision = "STALE_REVISION"
        case conflict = "CONFLICT"
        case timeout = "TIMEOUT"
        case sessionExpired = "SESSION_EXPIRED"
        case appInstanceMismatch = "APP_INSTANCE_MISMATCH"
        case frameTooLarge = "FRAME_TOO_LARGE"
        case rateLimited = "RATE_LIMITED"
        case internalError = "INTERNAL_ERROR"
    }

    public let code: Code
    public let message: String
    public let retryable: Bool
    public let details: [String: String]?
    /// Client-side correlation from the containing wire envelope.
    public package(set) var requestId: UUID? = nil

    private enum CodingKeys: String, CodingKey { case code, message, retryable, details }

    public init(_ code: Code, _ message: String, retryable: Bool = false, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct Response<Result: Codable & Sendable>: Codable, Sendable {
    public let version: String
    public let requestId: UUID?
    public let ok: Bool
    public let status: Status
    public let result: Result?
    public let error: Failure?
    public let durationMs: Int?

    public enum Status: String, Codable, Sendable {
        case completed, accepted, failed
    }

    public init(requestId: UUID, result: Result, durationMs: Int, accepted: Bool = false) {
        self.version = Wire.version
        self.requestId = requestId
        self.ok = true
        self.status = accepted ? .accepted : .completed
        self.result = result
        self.error = nil
        self.durationMs = durationMs
    }

    public init(requestId: UUID? = nil, error: Failure) {
        self.version = Wire.version
        self.requestId = requestId
        self.ok = false
        self.status = .failed
        self.result = nil
        self.error = error
        self.durationMs = nil
    }

    private enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case requestId, ok, status, result, error, durationMs
    }
}

public struct SessionIdentity: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let sessionId: UUID
    public let bundleId: String
    public let pid: Int32
    public let launchedAt: Date
    public let buildFingerprint: String

    public init(sessionId: UUID, bundleId: String, pid: Int32, launchedAt: Date, buildFingerprint: String) {
        self.protocolVersion = Wire.version
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.pid = pid
        self.launchedAt = launchedAt
        self.buildFingerprint = buildFingerprint
    }
}

public struct Capabilities: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let app: SessionIdentity
    public let domains: [String]
    public let methods: [String]
    public let routes: [RouteCapability]
    public let fixtures: [String]
    public let scopes: [String]
    public let actions: [String]?
    public let lifecycle: [LifecycleCapability]?
    public let readOnly: Bool
    public let limits: Limits

    public struct Limits: Codable, Sendable, Equatable {
        public let maxFrameBytes: Int
        public let maxRequestBytes: Int
        public let maxTimeoutMs: Int
        public let maxConcurrentConnections: Int
        public let requestsPerSecond: Int
    }

    public struct RouteCapability: Codable, Sendable, Equatable {
        public let id: String
        public let contextKeys: [String]
        public let windowId: String?
        public let accessibilityId: String?
        public let readinessGates: [String]?

        public init(
            id: String, contextKeys: [String] = [], windowId: String? = nil,
            accessibilityId: String? = nil, readinessGates: [String]? = nil
        ) {
            self.id = id
            self.contextKeys = contextKeys
            self.windowId = windowId
            self.accessibilityId = accessibilityId
            self.readinessGates = readinessGates
        }
    }

    public init(
        app: SessionIdentity, methods: [String], readOnly: Bool,
        routes: [RouteCapability] = [], fixtures: [String] = [], scopes: [String] = [], actions: [String] = [], lifecycle: [LifecycleCapability] = [],
        maxConcurrentConnections: Int, requestsPerSecond: Int
    ) {
        self.protocolVersion = Wire.version
        self.app = app
        self.domains = Set(methods.compactMap { $0.split(separator: ".").first.map(String.init) }).sorted()
        self.methods = methods
        self.readOnly = readOnly
        self.routes = routes
        self.fixtures = fixtures
        self.scopes = scopes
        self.actions = actions
        self.lifecycle = lifecycle
        self.limits = Limits(
            maxFrameBytes: Wire.maxFrameBytes, maxRequestBytes: Wire.maxRequestBytes,
            maxTimeoutMs: Wire.maxTimeoutMs, maxConcurrentConnections: maxConcurrentConnections,
            requestsPerSecond: requestsPerSecond
        )
    }
}
