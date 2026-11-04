import AgentDevKitCore
import AgentDevKitTransport
import Foundation

public struct AgentClient: Sendable {
    private let descriptor: SessionDescriptor

    public static func sessions() throws -> [SessionIdentity] {
        try discover().map(\.identity).sorted { $0.launchedAt < $1.launchedAt }
    }

    public init(session selector: String? = nil) throws {
        let all = try Self.discover()
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

    private static func discover() throws -> [SessionDescriptor] {
        do { return try SessionDirectory.discover() }
        catch { throw Failure(.sessionExpired, "Session discovery unavailable.") }
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
            let directory = try SessionDirectory(id: identity.sessionId)
            data = try await LocalSocket.exchange(
                JSONEncoder().encode(request), path: directory.socketPath,
                expectedPID: identity.pid, timeoutMs: request.timeoutMs
            )
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
