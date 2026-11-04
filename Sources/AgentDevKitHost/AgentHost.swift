import AgentDevKitCore
import AgentDevKitTransport
import CryptoKit
import Darwin
import Dispatch
import Foundation
import OSLog
import Security

/// Own one instance per opted-in application process. Call stop at session end.
public actor AgentHost {
    private let log = Logger(subsystem: "dev.agentdevkit", category: "commands")
    public enum Transport: Sendable {
        case local
        case appGroup(String)
        case pairedLoopback(directory: URL, makeIdentity: @Sendable () throws -> SecIdentity)
    }

    private var starting = false
    private var startupStops: [CheckedContinuation<Void, Never>] = []
    private var directory: SessionDirectory?
    private var loopback: LoopbackListener?
    private var active: SessionDescriptor?
    private var worker: Task<Void, Never>?
    private var seen: [UUID] = []
    private var bucketSecond: UInt64 = 0
    private var requestsInBucket = 0
    private static let rate = 30

    private let commands: [String: AppCommand]
    private let allowMutations: Bool
    private let routes: [Capabilities.RouteCapability]
    private let fixtures: [String]
    private let scopes: [String]
    private let actions: [String]
    private let lifecycle: [LifecycleCapability]
    private var mutationInProgress = false

    public init(
        commands: [AppCommand] = [], allowMutations: Bool = false,
        routes: [Capabilities.RouteCapability] = [], fixtures: [String] = [], scopes: [String] = [], actions: [String] = [],
        lifecycle: [LifecycleCapability] = []
    ) {
        var registry: [String: AppCommand] = [:]
        for command in commands {
            precondition(!command.method.hasPrefix("system.") && registry[command.method] == nil,
                         "App commands must have unique, non-system method names.")
            registry[command.method] = command
        }
        self.commands = registry
        self.allowMutations = allowMutations
        self.routes = routes
        self.fixtures = fixtures
        self.scopes = scopes
        self.actions = actions
        self.lifecycle = lifecycle
    }

    public func start() throws {
        try startUnix(.local)
    }

    public func start(transport: Transport) async throws {
        switch transport {
        case .local:
            try startUnix(.local)
        case .appGroup(let id):
            do { try startUnix(.appGroup(id)) }
            catch let failure as Failure { throw failure }
            catch {
                throw Failure(.sessionExpired, "App Group socket unavailable. Check signing, entitlement, permissions, and Unix socket path length.")
            }
        case .pairedLoopback(let folder, let makeIdentity):
            try checkAvailable()
            starting = true
            defer {
                starting = false
                for waiter in startupStops { waiter.resume() }
                startupStops.removeAll()
            }
            var descriptor = try makeDescriptor()
            let directory = try SessionDirectory(id: descriptor.identity.sessionId, source: .pairingDirectory(folder))
            try directory.create()
            do {
                let listener = try LoopbackListener(identity: makeIdentity())
                loopback = listener
                do {
                    descriptor.port = try await listener.start(handle: handler(), reject: { Self.encodeFailure($0) })
                    try Task.checkCancellation()
                    guard startupStops.isEmpty else { throw CancellationError() }
                    descriptor.certificatePin = listener.pin
                    try directory.publish(descriptor)
                } catch {
                    listener.close()
                    await listener.drain()
                    loopback = nil
                    throw error
                }
                self.directory = directory
                active = descriptor
            } catch {
                directory.remove()
                throw error
            }
        }
    }

    private func checkAvailable() throws {
        guard !starting, worker == nil, loopback == nil else {
            throw Failure(.conflict, "A bridge is already running or stopping.")
        }
    }

    private func makeDescriptor() throws -> SessionDescriptor {
        let id = UUID()
        let bundle = Bundle.main
        guard let bundleId = bundle.bundleIdentifier, let executable = bundle.executableURL,
              let launchedAt = SessionDirectory.launchDate(pid: getpid())
        else { throw Failure(.internalError, "Application identity unavailable.") }

        let file = try FileHandle(forReadingFrom: executable)
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure(.internalError, "Credential generation failed.") }
        return SessionDescriptor(
            identity: SessionIdentity(
                sessionId: id, bundleId: bundleId, pid: getpid(),
                launchedAt: launchedAt, buildFingerprint: fingerprint
            ),
            auth: secret.base64EncodedString()
        )
    }

    private func handler() -> @Sendable (Data, DispatchTime) async -> Data {
        { [weak self] data, acceptedAt in
            guard let self else { return Self.encodeFailure(Failure(.sessionExpired, "Session ended.")) }
            return await self.dispatch(data, acceptedAt: acceptedAt)
        }
    }

    private func startUnix(_ source: SessionSource) throws {
        try checkAvailable()
        let descriptor = try makeDescriptor()
        let directory = try SessionDirectory(id: descriptor.identity.sessionId, source: source)
        try directory.create()
        do {
            let listener = try LocalListener(path: directory.socketPath)
            do {
                try directory.publish(descriptor)
            } catch {
                listener.close()
                throw error
            }
            active = descriptor
            self.directory = directory
            let handle = handler()
            worker = Task {
                await listener.run(handle: handle) { failure in
                    Self.encodeFailure(failure)
                }
                directory.remove()
            }
        } catch {
            directory.remove()
            throw error
        }
    }

    public func stop() async {
        if starting {
            loopback?.close()
            await withCheckedContinuation { startupStops.append($0) }
            return
        }
        guard active != nil else { return }
        active = nil
        directory?.withdraw()
        if let loopback {
            loopback.close()
            await loopback.drain()
            directory?.remove()
            self.loopback = nil
        }
        if let worker {
            worker.cancel()
            await worker.value
            self.worker = nil
        }
        directory = nil
        seen.removeAll()
        requestsInBucket = 0
    }

    deinit {
        worker?.cancel()
        loopback?.close()
        if loopback != nil { directory?.remove() }
    }

    private func dispatch(_ data: Data, acceptedAt: DispatchTime) async -> Data {
        var requestId: UUID?
        var auditMethod = "unverified"
        var outcome = "completed"
        defer {
            log.info("method=\(auditMethod, privacy: .public) request=\(requestId?.uuidString ?? "-", privacy: .public) outcome=\(outcome, privacy: .public)")
        }
        do {
            guard let active else { throw Failure(.sessionExpired, "Session ended.") }
            let second = DispatchTime.now().uptimeNanoseconds / 1_000_000_000
            if second != bucketSecond {
                bucketSecond = second
                requestsInBucket = 0
            }
            guard requestsInBucket < Self.rate else {
                throw Failure(.rateLimited, "Request rate exceeded.", retryable: true)
            }
            requestsInBucket += 1

            let decoder = JSONDecoder()
            guard let header = try? decoder.decode(RequestHeader.self, from: data) else {
                throw Failure(.invalidParams, "Invalid request envelope.")
            }
            guard header.sessionId == active.identity.sessionId,
                  Self.matches(header.auth, active.auth) else {
                throw Failure(.authRequired, "Valid session credentials required.")
            }
            requestId = header.requestId
            guard header.version == Wire.version else { throw Failure(.unsupportedVersion, "Protocol version unsupported.") }
            let system = SystemMethod(rawValue: header.method)
            let appCommand = commands[header.method]
            guard system != nil || appCommand != nil else {
                throw Failure(.unknownMethod, "Method is not registered.")
            }
            auditMethod = header.method
            guard (1...Wire.maxTimeoutMs).contains(header.timeoutMs) else {
                throw Failure(.invalidParams, "Unsupported deadline.")
            }
            guard !seen.contains(header.requestId) else { throw Failure(.conflict, "Request ID already used.") }
            if seen.count == 256 { seen.removeFirst() }
            seen.append(header.requestId)

            let elapsed = DispatchTime.now().uptimeNanoseconds - acceptedAt.uptimeNanoseconds
            let started = ContinuousClock.now - .nanoseconds(Int64(elapsed))
            let context = CommandContext(
                requestId: header.requestId, deadline: started + .milliseconds(header.timeoutMs), started: started
            )
            try context.checkDeadline()
            if let command = appCommand {
                if command.mutating {
                    guard allowMutations else { throw Failure(.permissionDenied, "Session is read-only.") }
                    guard !mutationInProgress else { throw Failure(.conflict, "Another mutation is in progress.") }
                    mutationInProgress = true
                    defer { mutationInProgress = false }
                    return try await command.run(data, context)
                }
                return try await command.run(data, context)
            }
            guard (try? decoder.decode(Request<EmptyParameters>.self, from: data)) != nil else {
                throw Failure(.invalidParams, "Expected empty params.")
            }
            if system == .hello {
                return try JSONEncoder().encode(Response(
                    requestId: header.requestId, result: active.identity, durationMs: context.durationMs
                ))
            }
            let available = commands.values.filter { allowMutations || !$0.mutating }
            let capabilities = Capabilities(
                app: active.identity, methods: (SystemMethod.allCases.map(\.rawValue) + available.map(\.method)).sorted(),
                readOnly: !available.contains(where: \.mutating), routes: allowMutations ? routes : [],
                fixtures: allowMutations ? fixtures : [], scopes: scopes, actions: allowMutations ? actions : [],
                lifecycle: lifecycle, maxConcurrentConnections: LocalListener.concurrentConnections, requestsPerSecond: Self.rate
            )
            return try JSONEncoder().encode(Response(
                requestId: header.requestId, result: capabilities, durationMs: context.durationMs
            ))
        } catch {
            let failure = error as? Failure ?? Failure(.internalError, "Command failed.")
            outcome = failure.code.rawValue
            return Self.encodeFailure(failure, requestId: requestId)
        }
    }

    private static func matches(_ candidate: String, _ secret: String) -> Bool {
        guard candidate.utf8.count == secret.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate.utf8, secret.utf8) { difference |= a ^ b }
        return difference == 0
    }

    private static func encodeFailure(_ failure: Failure, requestId: UUID? = nil) -> Data {
        // This envelope has no custom encoders or values that can fail encoding.
        (try? JSONEncoder().encode(Response<EmptyParameters>(requestId: requestId, error: failure))) ?? Data()
    }
}
