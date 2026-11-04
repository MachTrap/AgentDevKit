import AgentDevKitCore
import AgentDevKitTransport
import Foundation

public typealias SessionSource = AgentDevKitTransport.SessionSource

public struct AgentClient: Sendable {
    private let source: SessionSource
    private let descriptor: SessionDescriptor

    public static func sessions() throws -> [SessionIdentity] {
        try sessions(source: .local)
    }

    public static func sessions(source: SessionSource) throws -> [SessionIdentity] {
        try discover(source).map(\.identity).sorted { $0.launchedAt < $1.launchedAt }
    }

    public init(session selector: String? = nil) throws {
        try self.init(session: selector, source: .local)
    }

    public init(session selector: String? = nil, source: SessionSource) throws {
        let all = try Self.discover(source)
        let matching = if let selector {
            all.filter { $0.identity.sessionId == UUID(uuidString: selector) || $0.identity.bundleId == selector }
        } else {
            all
        }
        guard let descriptor = matching.first else {
            throw Failure(.sessionExpired, "No matching live session.")
        }
        guard matching.count == 1 else {
            throw Failure(.conflict, "Select one session by its exact session ID.")
        }
        guard descriptor.identity.protocolVersion == Wire.version else {
            throw Failure(.unsupportedVersion, "Session protocol unsupported.")
        }
        self.descriptor = descriptor
        self.source = source
    }

    public func hello() async throws -> Response<SessionIdentity> {
        let response: Response<SessionIdentity> = try await send(SystemMethod.hello.rawValue, EmptyParameters())
        guard response.result == descriptor.identity else { throw Self.mismatch }
        return response
    }

    public func capabilities() async throws -> Response<Capabilities> {
        _ = try await hello()
        let response: Response<Capabilities> = try await send(SystemMethod.capabilities.rawValue, EmptyParameters())
        guard response.result?.app == descriptor.identity else { throw Self.mismatch }
        return response
    }

    private static var mismatch: Failure {
        Failure(.appInstanceMismatch, "Response does not match the selected app instance.")
    }

    private static func discover(_ source: SessionSource) throws -> [SessionDescriptor] {
        do { return try SessionDirectory.discover(source) }
        catch let failure as Failure { throw failure }
        catch { throw Failure(.sessionExpired, "Session discovery unavailable. Check directory access and permissions.") }
    }

    public func call<Input, Output>(
        _ command: Command<Input, Output>, _ params: Input, timeoutMs: Int = Wire.maxTimeoutMs
    ) async throws -> Response<Output> {
        _ = try await hello()
        return try await send(command.method, params, timeoutMs: timeoutMs)
    }

    private func send<Input: Codable & Sendable, Result: Codable & Sendable>(
        _ method: String, _ params: Input, timeoutMs: Int = Wire.maxTimeoutMs
    ) async throws -> Response<Result> {
        guard (1...Wire.maxTimeoutMs).contains(timeoutMs) else {
            throw Failure(.invalidParams, "Unsupported deadline.")
        }
        let identity = descriptor.identity
        guard SessionDirectory.launchDate(pid: identity.pid) == identity.launchedAt else {
            throw Failure(.sessionExpired, "Selected process has exited.")
        }
        let request = Request(sessionId: identity.sessionId, auth: descriptor.auth, method: method, params: params, timeoutMs: timeoutMs)
        let data: Data
        do {
            let payload = try JSONEncoder().encode(request)
            if let port = descriptor.port, let pin = descriptor.certificatePin {
                data = try await Loopback.exchange(payload, port: port, pin: pin, timeoutMs: timeoutMs)
            } else {
                let directory = try SessionDirectory(id: identity.sessionId, source: source)
                data = try await LocalSocket.exchange(
                    payload, path: directory.socketPath, expectedPID: identity.pid, timeoutMs: timeoutMs
                )
            }
        } catch SocketError.timedOut {
            throw Failure(.timeout, "Bridge did not respond before the deadline.", retryable: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(.sessionExpired, "Selected session is unreachable.", retryable: true)
        }

        guard let response = try? JSONDecoder().decode(Response<Result>.self, from: data),
              response.version == Wire.version else { throw Self.mismatch }
        if response.ok {
            guard response.status != .failed, response.requestId == request.requestId,
                  response.result != nil, response.error == nil else { throw Self.mismatch }
        } else {
            guard response.status == .failed, response.result == nil, var failure = response.error,
                  response.requestId == request.requestId || response.requestId == nil else { throw Self.mismatch }
            failure.requestId = response.requestId
            throw failure
        }
        return response
    }
}
