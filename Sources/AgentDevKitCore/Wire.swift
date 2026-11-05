import Foundation

public enum Wire {
    public static let version = "agentdevkit/2"
    public static let maxFrameBytes = 1_048_576
    /// Default request frame limit. A host may advertise a different value in its session descriptor.
    public static let maxRequestBytes = 4_096
    /// Default request deadline limit. A host may advertise up to `timeoutCeilingMs`.
    public static let maxTimeoutMs = 2_000
    public static let timeoutCeilingMs = 10_000
}

/// Request bounds a host publishes in its session descriptor.
public struct SessionLimits: Codable, Sendable, Equatable {
    public let maxRequestBytes: Int
    public let maxTimeoutMs: Int

    public init(maxRequestBytes: Int = Wire.maxRequestBytes, maxTimeoutMs: Int = Wire.maxTimeoutMs) {
        self.maxRequestBytes = maxRequestBytes
        self.maxTimeoutMs = maxTimeoutMs
    }
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
    /// An open set of protocol error codes. Codes added by later versions still decode.
    public struct Code: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static let authRequired = Code("AUTH_REQUIRED")
        public static let permissionDenied = Code("PERMISSION_DENIED")
        public static let unsupportedVersion = Code("UNSUPPORTED_VERSION")
        public static let unknownMethod = Code("UNKNOWN_METHOD")
        public static let invalidParams = Code("INVALID_PARAMS")
        public static let routeNotFound = Code("ROUTE_NOT_FOUND")
        public static let fixtureNotFound = Code("FIXTURE_NOT_FOUND")
        public static let actionNotFound = Code("ACTION_NOT_FOUND")
        public static let notReady = Code("NOT_READY")
        public static let cancelled = Code("CANCELLED")
        public static let staleRevision = Code("STALE_REVISION")
        public static let conflict = Code("CONFLICT")
        public static let timeout = Code("TIMEOUT")
        /// The selected process exited or its descriptor is stale.
        public static let sessionExpired = Code("SESSION_EXPIRED")
        /// No live session matched the selector.
        public static let sessionNotFound = Code("SESSION_NOT_FOUND")
        /// More than one live session matched the selector.
        public static let ambiguousSession = Code("AMBIGUOUS_SESSION")
        /// The connection closed after the request was sent.
        public static let connectionLost = Code("CONNECTION_LOST")
        /// The peer or response identity differs from the selected session.
        public static let appInstanceMismatch = Code("APP_INSTANCE_MISMATCH")
        /// The response could not be decoded or violates the envelope contract.
        public static let invalidResponse = Code("INVALID_RESPONSE")
        public static let frameTooLarge = Code("FRAME_TOO_LARGE")
        public static let responseTooLarge = Code("RESPONSE_TOO_LARGE")
        public static let rateLimited = Code("RATE_LIMITED")
        public static let internalError = Code("INTERNAL_ERROR")
    }

    public let code: Code
    public let message: String
    public let retryable: Bool
    public let details: [String: JSONValue]?
    /// Client-side correlation from the containing wire envelope.
    public package(set) var requestId: UUID? = nil

    private enum CodingKeys: String, CodingKey { case code, message, retryable, details }

    public init(_ code: Code, _ message: String, retryable: Bool = false, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct Response<Result: Codable & Sendable>: Codable, Sendable {
    public let version: String
    public let requestId: UUID?
    /// Present on every authenticated response, so the client can check the instance without a separate hello.
    public let sessionId: UUID?
    public let pid: Int32?
    public let ok: Bool
    public let status: Status
    public let result: Result?
    public let error: Failure?
    public let durationMs: Int?

    public enum Status: String, Codable, Sendable {
        case completed, accepted, failed
    }

    public init(requestId: UUID, result: Result, durationMs: Int, accepted: Bool = false, sessionId: UUID? = nil, pid: Int32? = nil) {
        self.version = Wire.version
        self.requestId = requestId
        self.sessionId = sessionId
        self.pid = pid
        self.ok = true
        self.status = accepted ? .accepted : .completed
        self.result = result
        self.error = nil
        self.durationMs = durationMs
    }

    public init(requestId: UUID? = nil, error: Failure, sessionId: UUID? = nil, pid: Int32? = nil) {
        self.version = Wire.version
        self.requestId = requestId
        self.sessionId = sessionId
        self.pid = pid
        self.ok = false
        self.status = .failed
        self.result = nil
        self.error = error
        self.durationMs = nil
    }

    private enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case requestId, sessionId, pid, ok, status, result, error, durationMs
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
    public let libraryVersion: String
    public let app: SessionIdentity
    public let domains: [String]
    public let methods: [String]
    public let routes: [RouteCapability]
    public let fixtures: [String]
    /// Argument schemas for fixtures that accept arguments, keyed by fixture ID. Absent before v0.4.
    public let fixtureArguments: [String: JSONValue]?
    public let scopes: [String]
    public let actions: [String]
    public let conditions: [ConditionCapability]
    public let lifecycle: [LifecycleCapability]
    public let diagnosticCategories: [String]
    /// In-process UI tools this session serves: `capture`, `tree`, `press`. Absent before v0.5 or when none.
    public let ui: [String]?
    public let readOnly: Bool
    public let limits: Limits

    /// The limits in effect for this session.
    public struct Limits: Codable, Sendable, Equatable {
        public let maxResponseBytes: Int
        public let maxRequestBytes: Int
        public let maxTimeoutMs: Int
        public let maxConcurrentConnections: Int
        public let requestsPerSecond: Int

        public init(maxResponseBytes: Int, maxRequestBytes: Int, maxTimeoutMs: Int,
                    maxConcurrentConnections: Int, requestsPerSecond: Int) {
            self.maxResponseBytes = maxResponseBytes
            self.maxRequestBytes = maxRequestBytes
            self.maxTimeoutMs = maxTimeoutMs
            self.maxConcurrentConnections = maxConcurrentConnections
            self.requestsPerSecond = requestsPerSecond
        }
    }

    public struct RouteCapability: Codable, Sendable, Equatable {
        public let id: String
        /// JSON Schema subset describing the accepted `context` object.
        public let contextSchema: JSONValue
        public let windowId: String?
        public let accessibilityId: String?
        public let readinessGates: [String]

        public init(id: String, contextSchema: JSONValue, windowId: String? = nil,
                    accessibilityId: String? = nil, readinessGates: [String] = []) {
            self.id = id
            self.contextSchema = contextSchema
            self.windowId = windowId
            self.accessibilityId = accessibilityId
            self.readinessGates = readinessGates
        }
    }

    public struct ConditionCapability: Codable, Sendable, Equatable {
        public let id: String
        /// JSON Schema subset describing the accepted `arguments` object.
        public let argumentsSchema: JSONValue

        public init(id: String, argumentsSchema: JSONValue) {
            self.id = id
            self.argumentsSchema = argumentsSchema
        }
    }

    public init(
        app: SessionIdentity, methods: [String], readOnly: Bool,
        routes: [RouteCapability] = [], fixtures: [String] = [], scopes: [String] = [], actions: [String] = [],
        conditions: [ConditionCapability] = [], lifecycle: [LifecycleCapability] = [], diagnosticCategories: [String] = [],
        fixtureArguments: [String: JSONValue] = [:], ui: [String] = [], limits: Limits
    ) {
        self.fixtureArguments = fixtureArguments.isEmpty ? nil : fixtureArguments
        self.ui = ui.isEmpty ? nil : ui
        self.protocolVersion = Wire.version
        self.libraryVersion = AgentDevKitVersion.current
        self.app = app
        self.domains = Set(methods.compactMap { $0.split(separator: ".").first.map(String.init) }).sorted()
        self.methods = methods
        self.readOnly = readOnly
        self.routes = routes
        self.fixtures = fixtures
        self.scopes = scopes
        self.actions = actions
        self.conditions = conditions
        self.lifecycle = lifecycle
        self.diagnosticCategories = diagnosticCategories
        self.limits = limits
    }
}
