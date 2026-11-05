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

    /// How long the client keeps reading after the request deadline. The host answers TIMEOUT
    /// with its blockers and hints at the deadline. On a loaded machine that answer can arrive a
    /// little late, and dropping it would leave only a bare transport timeout.
    public static let responseGraceMs = 1_000

    /// Live sessions at `location`, oldest first, including sessions that speak another protocol version.
    public static func sessions(at location: SessionLocation = .local) throws -> [SessionIdentity] {
        try discover(location).map(\.identity).sorted { $0.launchedAt < $1.launchedAt }
    }

    /// Selects one live session by exact session UUID or bundle ID. Without a selector, exactly one session must exist.
    /// At `.local`, a bundle ID that matches no unsandboxed session is also looked up in that app's own
    /// sandbox container, so sandboxed Testing builds need no extra configuration.
    public init(session selector: String? = nil, at location: SessionLocation = .local) throws {
        var location = location
        var matching = try Self.matching(selector, in: Self.discover(location))
        if matching.isEmpty, location == .local, let selector, UUID(uuidString: selector) == nil {
            let container = SessionLocation.appContainer(selector)
            matching = try Self.matching(selector, in: Self.discover(container))
            if !matching.isEmpty { location = container }
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

    /// The live session published by a process, looked up in the per-user directory and, with a bundle ID,
    /// in that app's sandbox container.
    public static func session(pid: Int32, bundleId: String? = nil) -> SessionIdentity? {
        var locations: [SessionLocation] = [.local]
        if let bundleId { locations.append(.appContainer(bundleId)) }
        for location in locations {
            if let match = (try? discover(location))?.first(where: { $0.identity.pid == pid }) { return match.identity }
        }
        return nil
    }

    private static func matching(_ selector: String?, in all: [SessionDescriptor]) -> [SessionDescriptor] {
        guard let selector else { return all }
        return all.filter { $0.identity.sessionId == UUID(uuidString: selector) || $0.identity.bundleId == selector }
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

    /// Sends a typed command. RATE_LIMITED replies are retried with backoff, because the host rejects them
    /// before running anything; the retry reuses the request ID.
    public func call<Input, Output>(
        _ command: Command<Input, Output>, _ params: Input, timeoutMs: Int? = nil, requestId: UUID = UUID()
    ) async throws -> Response<Output> {
        var delay = 120
        for attempt in 0..<6 {
            do { return try await send(command.method, params, timeoutMs: timeoutMs, requestId: requestId) }
            catch let failure as Failure where failure.code == .rateLimited && attempt < 5 {
                try await Task.sleep(for: .milliseconds(delay))
                delay = min(1_000, delay * 2)
            }
        }
        return try await send(command.method, params, timeoutMs: timeoutMs, requestId: requestId)
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
        let transportMs = timeoutMs + Self.responseGraceMs
        do {
            if let port = descriptor.port, let pin = descriptor.certificatePin {
                data = try await Loopback.exchange(payload, port: port, pin: pin, timeoutMs: transportMs)
            } else {
                let directory = try SessionDirectory(id: identity.sessionId, source: location)
                data = try await LocalSocket.exchange(payload, path: directory.socketPath,
                                                      expectedPID: identity.pid, timeoutMs: transportMs)
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

/// Where the CLI and MCP sidecar find the session to use when no `--session` is given:
/// `AGENTDEVKIT_SESSION`, then a `.agentdevkit.json` project file (`{"session": "com.example.app.testing"}`)
/// found by walking up from the current directory. An explicit selector always wins.
public enum SessionDefaults {
    public enum Source: String, Sendable { case flag, environment, projectFile }

    public struct Resolved: Sendable, Equatable {
        public let selector: String
        public let source: Source
        /// The project file the selector came from.
        public let file: URL?
    }

    public static let environmentKey = "AGENTDEVKIT_SESSION"
    public static let fileName = ".agentdevkit.json"

    public static func resolve(
        explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> Resolved? {
        if let explicit, !explicit.isEmpty { return Resolved(selector: explicit, source: .flag, file: nil) }
        if let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return Resolved(selector: value, source: .environment, file: nil)
        }
        guard let file = projectFile(from: directory) else { return nil }
        struct Project: Decodable { let session: String? }
        guard let data = try? Data(contentsOf: file), data.count <= 65_536,
              let project = try? JSONDecoder().decode(Project.self, from: data) else {
            throw Failure(.invalidParams, "\(file.path) is not a JSON object with a session string.", details: ["field": "session"])
        }
        guard let session = project.session?.trimmingCharacters(in: .whitespaces), !session.isEmpty else { return nil }
        return Resolved(selector: session, source: .projectFile, file: file)
    }

    /// The nearest `.agentdevkit.json` in `directory` or an ancestor.
    public static func projectFile(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        for _ in 0..<64 {
            let candidate = current.appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }
}
