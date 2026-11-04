import AgentDevKitCore
import AgentDevKitTransport
import Foundation

public typealias SessionLocation = AgentDevKitTransport.SessionLocation

/// A connection to one selected session. Each call opens one authenticated connection, and
/// every response must carry the selected session ID and PID.
public struct AgentClient: Sendable {
    private let location: SessionLocation
    private let descriptor: SessionDescriptor

    /// The identity published by the selected session.
    public var identity: SessionIdentity { descriptor.identity }
    /// Request bounds published by the session.
    public var limits: SessionLimits { descriptor.limits ?? SessionLimits() }

    /// Live sessions at `location`, oldest first, including sessions that speak another protocol version.
    public static func sessions(at location: SessionLocation = .local) throws -> [SessionIdentity] {
        try discover(location).map(\.identity).sorted { $0.launchedAt < $1.launchedAt }
    }

    /// Selects one live session by exact session UUID or bundle ID. Without a selector, exactly one session must exist.
    public init(session selector: String? = nil, at location: SessionLocation = .local) throws {
        let all = try Self.discover(location)
        let matching = if let selector {
            all.filter { $0.identity.sessionId == UUID(uuidString: selector) || $0.identity.bundleId == selector }
        } else {
            all
        }
        guard let descriptor = matching.first else {
            throw Failure(.sessionNotFound, "No matching live session.",
                          details: selector.map { ["selector": .string($0)] })
        }
        guard matching.count == 1 else {
            throw Failure(.ambiguousSession, "Select one session by its exact session ID.",
                          details: ["sessionIds": .array(matching.map { .string($0.identity.sessionId.uuidString) })])
        }
        guard descriptor.identity.protocolVersion == Wire.version else {
            throw Self.versionMismatch(descriptor.identity.protocolVersion)
        }
        self.descriptor = descriptor
        self.location = location
    }

    static func versionMismatch(_ sessionProtocol: String) -> Failure {
        Failure(.unsupportedVersion, "Session protocol unsupported.", details: [
            "sessionProtocol": .string(sessionProtocol), "clientProtocol": .string(Wire.version),
            "remedy": .string("Use tools built from the same AgentDevKit release as the app, or rebuild the app with AgentDevKit \(AgentDevKitVersion.current).")
        ])
    }

    /// Reads the live identity and checks that it matches the descriptor completely.
    public func hello() async throws -> Response<SessionIdentity> {
        let response: Response<SessionIdentity> = try await send(SystemMethod.hello.rawValue, EmptyParameters())
        guard response.result == descriptor.identity else { throw Self.mismatch }
        return response
    }

    public func capabilities(timeoutMs: Int? = nil) async throws -> Response<Capabilities> {
        let response: Response<Capabilities> = try await send(SystemMethod.capabilities.rawValue, EmptyParameters(), timeoutMs: timeoutMs)
        guard response.result?.app == descriptor.identity else { throw Self.mismatch }
        return response
    }

    public func call<Input, Output>(
        _ command: Command<Input, Output>, _ params: Input, timeoutMs: Int? = nil, requestId: UUID = UUID()
    ) async throws -> Response<Output> {
        try await send(command.method, params, timeoutMs: timeoutMs, requestId: requestId)
    }

    private static var mismatch: Failure {
        Failure(.appInstanceMismatch, "Response does not match the selected app instance.")
    }

    private static var invalid: Failure {
        Failure(.invalidResponse, "The bridge returned a response that violates the protocol.")
    }

    private static func discover(_ location: SessionLocation) throws -> [SessionDescriptor] {
        do { return try SessionDirectory.discover(location) }
        catch let failure as Failure { throw failure }
        catch { throw Failure(.sessionNotFound, "Session discovery unavailable. Check directory access and permissions.") }
    }

    private func send<Input: Codable & Sendable, Result: Codable & Sendable>(
        _ method: String, _ params: Input, timeoutMs: Int? = nil, requestId: UUID = UUID()
    ) async throws -> Response<Result> {
        let timeoutMs = timeoutMs ?? min(Wire.maxTimeoutMs, limits.maxTimeoutMs)
        guard (1...limits.maxTimeoutMs).contains(timeoutMs) else {
            throw Failure(.invalidParams, "Unsupported deadline.",
                          details: ["field": "timeoutMs", "maxTimeoutMs": .integer(Int64(limits.maxTimeoutMs))])
        }
        let identity = descriptor.identity
        guard SessionDirectory.launchDate(pid: identity.pid) == identity.launchedAt else {
            throw Failure(.sessionExpired, "Selected process has exited.")
        }
        let request = Request(requestId: requestId, sessionId: identity.sessionId, auth: descriptor.auth,
                              method: method, params: params, timeoutMs: timeoutMs)
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= limits.maxRequestBytes else {
            throw Failure(.frameTooLarge, "Request exceeds the session's request limit.",
                          details: ["limitBytes": .integer(Int64(limits.maxRequestBytes))])
        }
        let data: Data
        do {
            if let port = descriptor.port, let pin = descriptor.certificatePin {
                data = try await Loopback.exchange(payload, port: port, pin: pin, timeoutMs: timeoutMs)
            } else {
                let directory = try SessionDirectory(id: identity.sessionId, source: location)
                data = try await LocalSocket.exchange(payload, path: directory.socketPath,
                                                      expectedPID: identity.pid, timeoutMs: timeoutMs)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.transportFailure(error)
        }

        guard let response = try? JSONDecoder().decode(Response<Result>.self, from: data) else { throw Self.invalid }
        guard response.version == Wire.version else { throw Self.versionMismatch(response.version) }
        // Authenticated responses identify the instance that produced them.
        if response.requestId != nil {
            guard response.sessionId == identity.sessionId, response.pid == identity.pid else { throw Self.mismatch }
        }
        if response.ok {
            guard response.status != .failed, response.requestId == request.requestId,
                  response.result != nil, response.error == nil else { throw Self.invalid }
        } else {
            guard response.status == .failed, response.result == nil, var failure = response.error,
                  response.requestId == request.requestId || response.requestId == nil else { throw Self.invalid }
            failure.requestId = response.requestId
            throw failure
        }
        return response
    }

    private static func transportFailure(_ error: any Error) -> Failure {
        switch error as? SocketError {
        case .timedOut?:
            return Failure(.timeout, "Bridge did not respond before the deadline.", retryable: true)
        case .connectFailed?:
            return Failure(.sessionExpired, "Selected session is not accepting connections.", retryable: true)
        case .peerMismatch?:
            return Failure(.appInstanceMismatch, "The listening peer is not the selected app instance.")
        case .oversized?:
            return Failure(.responseTooLarge, "Response exceeds the frame limit.")
        case .emptyFrame?:
            return invalid
        default:
            return Failure(.connectionLost, "The connection closed before the response arrived.", retryable: true)
        }
    }
}
