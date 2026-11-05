import AgentDevKitCore
import AgentDevKitTransport
import CryptoKit
import Darwin
import Dispatch
import Foundation
import OSLog
import Security

/// Own one instance per opted-in application process. Call `stop()` at session end.
public actor AgentHost {
    private let log = Logger(subsystem: "dev.agentdevkit", category: "commands")

    private var starting = false
    private var startupStops: [CheckedContinuation<Void, Never>] = []
    private var directory: SessionDirectory?
    private var loopback: LoopbackListener?
    private var active: SessionDescriptor?
    private var worker: Task<Void, Never>?
    private var replay = ReplayCache(entries: 256, bytes: 0)
    private var bucketSecond: UInt64 = 0
    private var requestsInBucket = 0
    private var rejectedInBucket = 0
    private var mutationInProgress = false
    public private(set) var state: AgentHostState = .stopped
    private var stateObservers: [UUID: AsyncStream<AgentHostState>.Continuation] = [:]

    private let configuration: AgentHostConfiguration
    private let limits: AgentHostConfiguration.Limits
    private let allowMutations: Bool
    private let catalog: AgentCatalog
    private let commands: [String: AppCommand]
    private let conditions: [Capabilities.ConditionCapability]

    /// Serves the built-in protocol methods through an app adapter, plus any catalog commands.
    /// Pass `allowMutations: true` only after an explicit opt-in opened isolated test storage.
    public init<Adapter: AgentAdapter>(
        adapter: Adapter, runtime: AgentRuntime, catalog: AgentCatalog = AgentCatalog(),
        allowMutations: Bool = false, configuration: AgentHostConfiguration = AgentHostConfiguration()
    ) {
        let visible = catalog.visible(allowMutations: allowMutations)
        let limits = configuration.limits.clamped
        // Built from the full catalog so a read-only session answers mutating methods with PERMISSION_DENIED.
        let builtins = Builtins.commands(adapter: adapter, runtime: runtime, catalog: catalog, allowMutations: allowMutations,
                                         waitMargin: .milliseconds(limits.waitMarginMs))
            + UIInspection.commands(adapter: adapter, runtime: runtime, access: catalog.ui, maxResponseBytes: limits.maxResponseBytes)
        self.init(visible: visible, commands: builtins + catalog.commands, allowMutations: allowMutations,
                  configuration: configuration, conditions: Builtins.builtinConditions)
    }

    /// Serves only `system.*` and the catalog's typed commands. Use this when app state is not on the main actor.
    public init(catalog: AgentCatalog = AgentCatalog(scopes: []), allowMutations: Bool = false,
                configuration: AgentHostConfiguration = AgentHostConfiguration()) {
        self.init(visible: catalog.visible(allowMutations: allowMutations), commands: catalog.commands,
                  allowMutations: allowMutations, configuration: configuration, conditions: [])
    }

    /// Registers every command, so a read-only session can answer a mutating method with PERMISSION_DENIED.
    /// Capabilities list only the commands the session may run.
    private init(visible: AgentCatalog, commands: [AppCommand], allowMutations: Bool,
                 configuration: AgentHostConfiguration, conditions: [Capabilities.ConditionCapability]) {
        var registry: [String: AppCommand] = [:]
        for command in commands {
            precondition(!command.method.hasPrefix("system.") && registry[command.method] == nil,
                         "Command methods must be unique and outside the system namespace.")
            registry[command.method] = command
        }
        var catalog = visible
        if allowMutations, registry[AppCommands.prepare.method] != nil,
           !catalog.lifecycle.contains(where: { $0.kind == .scenario && $0.name == "scenario.prepare" }) {
            catalog.lifecycle.append(LifecycleCapability(kind: .scenario, name: "scenario.prepare"))
        }
        self.catalog = catalog
        self.commands = registry
        self.allowMutations = allowMutations
        self.configuration = configuration
        self.limits = configuration.limits.clamped
        self.conditions = conditions + visible.conditions.map {
            Capabilities.ConditionCapability(id: $0.id, argumentsSchema: $0.arguments.json)
        }
        replay = ReplayCache(entries: limits.retainedRequestIds, bytes: limits.replayCacheBytes)
    }

    // MARK: State

    /// Observe state changes. The stream yields the current state first.
    public func stateUpdates() -> AsyncStream<AgentHostState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentHostState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        continuation.yield(state)
        stateObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { stateObservers[id] = nil }

    private func setState(_ next: AgentHostState) {
        state = next
        for observer in stateObservers.values { observer.yield(next) }
    }

    private var listenerLimits: ListenerLimits {
        ListenerLimits(connections: limits.maxConnections, maxRequestBytes: limits.maxRequestBytes,
                       readTimeoutMs: limits.requestReadTimeoutMs, connectionTimeoutMs: limits.maxTimeoutMs)
    }

    // MARK: Start and stop

    /// Publishes a session at `location`. A paired-loopback folder also needs a fresh
    /// TLS identity for every start; the app must hold the folder's security scope until `stop()`.
    /// In the App Sandbox, `.local` publishes inside the app's own container (`.appContainer`),
    /// so a sandboxed Testing build needs no App Group or pairing folder.
    public func start(
        at requested: SessionLocation = .local, loopbackIdentity: (@Sendable () throws -> SecIdentity)? = nil
    ) async throws(AgentHostStartError) {
        let location: SessionLocation = if requested == .local, let container = SessionDirectory.sandboxContainerID {
            .appContainer(container)
        } else {
            requested
        }
        guard !starting, worker == nil, loopback == nil, active == nil else { throw .alreadyRunning }
        starting = true
        setState(.starting)
        defer {
            starting = false
            for waiter in startupStops { waiter.resume() }
            startupStops.removeAll()
        }
        do {
            switch location {
            case .local, .appGroup, .appContainer:
                try startUnix(location)
            case .pairingDirectory(let folder):
                guard let loopbackIdentity else { throw AgentHostStartError.listenerFailed }
                try await startLoopback(folder: folder, makeIdentity: loopbackIdentity)
            }
        } catch {
            let failure = Self.startError(error, location: location)
            setState(.failed(failure))
            throw failure
        }
        if let active { setState(.running(active.identity)) }
    }

    private func startLoopback(folder: URL, makeIdentity: @Sendable () throws -> SecIdentity) async throws {
        var descriptor = try makeDescriptor()
        let directory = try SessionDirectory(id: descriptor.identity.sessionId, source: .pairingDirectory(folder))
        try directory.create()
        do {
            let listener = try LoopbackListener(identity: makeIdentity(), limits: listenerLimits)
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

    private func startUnix(_ location: SessionLocation) throws {
        let descriptor = try makeDescriptor()
        let directory = try SessionDirectory(id: descriptor.identity.sessionId, source: location)
        try directory.create()
        do {
            let listener = try LocalListener(path: directory.socketPath, limits: listenerLimits)
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
                await listener.run(handle: handle) { failure in Self.encodeFailure(failure) }
                directory.remove()
            }
        } catch {
            directory.remove()
            throw error
        }
    }

    private static func startError(_ error: any Error, location: SessionLocation) -> AgentHostStartError {
        switch error {
        case let error as AgentHostStartError: return error
        case is CancellationError: return .cancelled
        case SocketError.pathTooLong: return .socketPathTooLong
        case is Failure:
            // Session directory roots report unavailable App Group or pairing folders as failures.
            switch location {
            case .appGroup: return .appGroupUnavailable
            case .pairingDirectory: return .pairingFolderInvalid
            case .local, .appContainer: return .listenerFailed
            }
        default: return .listenerFailed
        }
    }

    private func makeDescriptor() throws -> SessionDescriptor {
        guard let launchedAt = SessionDirectory.launchDate(pid: getpid()) else {
            throw AgentHostStartError.identityUnavailable
        }
        let bundleId: String
        let fingerprint: String
        switch configuration.identity {
        case .fixed(let fixedBundleId, let buildFingerprint):
            guard !fixedBundleId.isEmpty, !buildFingerprint.isEmpty else { throw AgentHostStartError.identityUnavailable }
            bundleId = fixedBundleId
            fingerprint = buildFingerprint
        case .mainBundle:
            let bundle = Bundle.main
            guard let mainBundleId = bundle.bundleIdentifier, let executable = bundle.executableURL,
                  let file = try? FileHandle(forReadingFrom: executable)
            else { throw AgentHostStartError.identityUnavailable }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            bundleId = mainBundleId
            fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AgentHostStartError.identityUnavailable }
        return SessionDescriptor(
            identity: SessionIdentity(sessionId: UUID(), bundleId: bundleId, pid: getpid(),
                                      launchedAt: launchedAt, buildFingerprint: fingerprint),
            auth: secret.base64EncodedString(),
            limits: SessionLimits(maxRequestBytes: limits.maxRequestBytes, maxTimeoutMs: limits.maxTimeoutMs)
        )
    }

    private func handler() -> @Sendable (Data, DispatchTime) async -> Data {
        { [weak self] data, acceptedAt in
            guard let self else { return Self.encodeFailure(Failure(.sessionExpired, "Session ended.")) }
            return await self.dispatch(data, acceptedAt: acceptedAt)
        }
    }

    public func stop() async {
        if starting {
            loopback?.close()
            await withCheckedContinuation { startupStops.append($0) }
            return
        }
        guard active != nil else { return }
        setState(.stopping)
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
        replay.removeAll()
        requestsInBucket = 0
        rejectedInBucket = 0
        setState(.stopped)
    }

    deinit {
        worker?.cancel()
        loopback?.close()
        if loopback != nil { directory?.remove() }
    }

    // MARK: Dispatch

    private func dispatch(_ data: Data, acceptedAt: DispatchTime) async -> Data {
        var requestId: UUID?
        var authenticated: SessionIdentity?
        var auditMethod = "unverified"
        var outcome = "completed"
        var replayKey: (id: UUID, digest: Data)?
        defer {
            log.info("method=\(auditMethod, privacy: .public) request=\(requestId?.uuidString ?? "-", privacy: .public) outcome=\(outcome, privacy: .public)")
        }
        do {
            guard let active else { throw Failure(.sessionExpired, "Session ended.") }
            let second = DispatchTime.now().uptimeNanoseconds / 1_000_000_000
            if second != bucketSecond {
                bucketSecond = second
                requestsInBucket = 0
                rejectedInBucket = 0
            }

            // Unauthenticated peers draw from a separate, smaller budget so they
            // cannot exhaust the rate available to the authenticated client.
            let decoder = JSONDecoder()
            guard let header = try? decoder.decode(RequestHeader.self, from: data) else {
                throw try rejected(Failure(.invalidParams, "Invalid request envelope."))
            }
            guard header.sessionId == active.identity.sessionId, Self.matches(header.auth, active.auth) else {
                throw try rejected(Failure(.authRequired, "Valid session credentials required."))
            }
            authenticated = active.identity
            guard requestsInBucket < limits.requestsPerSecond else {
                throw Failure(.rateLimited, "Request rate exceeded.", retryable: true)
            }
            requestsInBucket += 1
            requestId = header.requestId
            guard header.version == Wire.version else {
                throw Failure(.unsupportedVersion, "Protocol version unsupported.",
                              details: ["supported": [.string(Wire.version)], "requested": .string(header.version)])
            }
            let system = SystemMethod(rawValue: header.method)
            let appCommand = commands[header.method]
            guard system != nil || appCommand != nil else {
                throw Failure(.unknownMethod, "Method is not registered.", details: ["method": .string(header.method)])
            }
            auditMethod = header.method
            guard (1...limits.maxTimeoutMs).contains(header.timeoutMs) else {
                throw Failure(.invalidParams, "Unsupported deadline.",
                              details: ["field": "timeoutMs", "maxTimeoutMs": .integer(Int64(limits.maxTimeoutMs))])
            }
            guard let params = (try? decoder.decode(ParamsEnvelope.self, from: data))?.params.objectValue else {
                throw Failure(.invalidParams, "Request params must be an object.", details: ["field": "params"])
            }
            let digest = Self.digest(method: header.method, params: params)
            switch replay.lookup(header.requestId, digest: digest) {
            case .new:
                replay.begin(header.requestId, digest: digest)
                replayKey = (header.requestId, digest)
            case .replay(let cached):
                outcome = "replayed"
                return cached
            case .inFlight:
                throw Failure(.conflict, "A request with this ID is still running.", retryable: true)
            case .mismatch:
                throw Failure(.conflict, "Request ID already used for a different request.")
            case .evicted:
                throw Failure(.conflict, "Response for this request ID is no longer retained.")
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - acceptedAt.uptimeNanoseconds
            let started = ContinuousClock.now - .nanoseconds(Int64(elapsed))
            let context = CommandContext(
                requestId: header.requestId, deadline: started + .milliseconds(header.timeoutMs), started: started,
                sessionId: active.identity.sessionId, pid: active.identity.pid
            )
            let response: Data
            do {
                response = try await run(system: system, command: appCommand, params: params, context: context, identity: active.identity)
            } catch {
                let failure = mapError(error)
                outcome = failure.code.rawValue
                let encoded = Self.encodeFailure(failure, requestId: requestId, identity: active.identity)
                replay.finish(header.requestId, digest: digest, response: encoded)
                return encoded
            }
            replay.finish(header.requestId, digest: digest, response: response)
            return response
        } catch {
            if let replayKey { replay.finish(replayKey.id, digest: replayKey.digest, response: nil) }
            let failure = mapError(error)
            outcome = failure.code.rawValue
            return Self.encodeFailure(failure, requestId: requestId, identity: authenticated)
        }
    }

    private func run(
        system: SystemMethod?, command: AppCommand?, params: [String: JSONValue],
        context: CommandContext, identity: SessionIdentity
    ) async throws -> Data {
        try context.checkDeadline()
        if let command {
            guard command.mutating else { return try bounded(await command.run(params, context)) }
            guard allowMutations else { throw Failure(.permissionDenied, "Session is read-only.") }
            guard !mutationInProgress else { throw Failure(.conflict, "Another mutation is in progress.", retryable: true) }
            mutationInProgress = true
            defer { mutationInProgress = false }
            return try bounded(await command.run(params, context))
        }
        guard params.isEmpty else {
            throw Failure(.invalidParams, "Expected empty params.", details: ["field": .string("params." + (params.keys.sorted().first ?? ""))])
        }
        if system == .hello { return try bounded(context.encode(identity)) }
        let available = commands.values.filter { allowMutations || !$0.mutating }
        let methods = SystemMethod.allCases.map(\.rawValue) + available.map(\.method)
        let capabilities = Capabilities(
            app: identity, methods: methods.sorted(), readOnly: !available.contains(where: \.mutating),
            routes: catalog.routes.map(\.capability), fixtures: catalog.fixtures, scopes: catalog.scopes,
            actions: catalog.actions.map(\.id), conditions: conditions, lifecycle: catalog.lifecycle,
            diagnosticCategories: catalog.diagnosticCategories,
            fixtureArguments: catalog.fixtureArguments.mapValues(\.json),
            ui: catalog.ui.names,
            limits: .init(maxResponseBytes: limits.maxResponseBytes, maxRequestBytes: limits.maxRequestBytes,
                          maxTimeoutMs: limits.maxTimeoutMs, maxConcurrentConnections: limits.maxConnections,
                          requestsPerSecond: limits.requestsPerSecond)
        )
        return try bounded(context.encode(capabilities))
    }

    private func rejected(_ failure: Failure) throws -> Failure {
        guard rejectedInBucket < limits.rejectedRequestsPerSecond else {
            throw Failure(.rateLimited, "Request rate exceeded.", retryable: true)
        }
        rejectedInBucket += 1
        return failure
    }

    private func bounded(_ response: Data) throws -> Data {
        guard response.count <= limits.maxResponseBytes else {
            throw Failure(.responseTooLarge, "Response exceeds the frame limit. Narrow the scope or page size.",
                          details: ["limitBytes": .integer(Int64(limits.maxResponseBytes))])
        }
        return response
    }

    private func mapError(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return Failure(.cancelled, "Request cancelled.") }
        if let mapped = configuration.onError?(error) { return mapped }
        return Failure(.internalError, "Command failed.", details: ["errorType": .string(String(describing: type(of: error)))])
    }

    private static func digest(method: String, params: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hash = SHA256()
        hash.update(data: Data(method.utf8))
        hash.update(data: Data([0]))
        hash.update(data: (try? encoder.encode(params)) ?? Data())
        return Data(hash.finalize())
    }

    private static func matches(_ candidate: String, _ secret: String) -> Bool {
        guard candidate.utf8.count == secret.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate.utf8, secret.utf8) { difference |= a ^ b }
        return difference == 0
    }

    private static func encodeFailure(_ failure: Failure, requestId: UUID? = nil, identity: SessionIdentity? = nil) -> Data {
        // This envelope has no custom encoders or values that can fail encoding.
        (try? JSONEncoder().encode(Response<EmptyParameters>(
            requestId: requestId, error: failure, sessionId: identity?.sessionId, pid: identity?.pid
        ))) ?? Data()
    }
}

private struct ParamsEnvelope: Decodable {
    let params: JSONValue
}

/// Bounded request-ID memory. A retry with the same method and params receives the original response.
struct ReplayCache {
    enum Lookup { case new, replay(Data), inFlight, mismatch, evicted }

    private struct Entry {
        let digest: Data
        var response: Data?
        var finished: Bool
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var storedBytes = 0
    private let maxEntries: Int
    private let maxBytes: Int

    init(entries: Int, bytes: Int) {
        maxEntries = max(1, entries)
        maxBytes = max(0, bytes)
    }

    func lookup(_ id: UUID, digest: Data) -> Lookup {
        guard let entry = entries[id] else { return .new }
        guard entry.digest == digest else { return .mismatch }
        guard entry.finished else { return .inFlight }
        return entry.response.map(Lookup.replay) ?? .evicted
    }

    mutating func begin(_ id: UUID, digest: Data) {
        if order.count >= maxEntries, let oldest = order.first {
            order.removeFirst()
            storedBytes -= entries.removeValue(forKey: oldest)?.response?.count ?? 0
        }
        entries[id] = Entry(digest: digest, response: nil, finished: false)
        order.append(id)
    }

    /// Records the response. A nil response forgets the ID, so the request may be retried.
    mutating func finish(_ id: UUID, digest: Data, response: Data?) {
        guard entries[id]?.digest == digest else { return }
        guard let response else {
            entries[id] = nil
            order.removeAll { $0 == id }
            return
        }
        entries[id]?.finished = true
        guard response.count <= maxBytes else { return }
        entries[id]?.response = response
        storedBytes += response.count
        // Drop the oldest cached bodies first. Their IDs stay reserved and report `evicted`.
        var index = 0
        while storedBytes > maxBytes, index < order.count {
            let candidate = order[index]
            if candidate != id, let body = entries[candidate]?.response {
                entries[candidate]?.response = nil
                storedBytes -= body.count
            }
            index += 1
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        storedBytes = 0
    }
}
