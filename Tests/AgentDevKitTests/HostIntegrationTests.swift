import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import AgentDevKitTransport
import Darwin
import Foundation
import Testing

// These tests run a real host in this process over a real Unix socket.
// Each host has a unique bundle ID, so discovery never selects another test's session.

struct Echo: Codable, Sendable {
    let name: String
    let count: Int?
}

struct Blob: Codable, Sendable {
    let text: String
}

struct TestFailure: Error {}

enum TestCommands {
    static let echo = Command<Echo, Echo>("test.echo")
    static let mutate = Command<EmptyParameters, Echo>("test.mutate", mutating: true)
    static let large = Command<EmptyParameters, Blob>("test.large")
    static let fail = Command<EmptyParameters, Echo>("test.fail")
    static let counter = Command<EmptyParameters, Echo>("test.counter", mutating: true)

    @MainActor static var count = 0

    static let all: [AppCommand] = [
        AppCommand(echo, parameters: ObjectSchema(["name": .string(maxLength: 64), "count": .integer(minimum: 0)],
                                                  required: ["name"])) { input, _ in input },
        AppCommand(mutate, parameters: .empty) { _, _ in Echo(name: "mutated", count: nil) },
        AppCommand(large, parameters: .empty) { _, _ in Blob(text: String(repeating: "x", count: 4_096)) },
        AppCommand(fail, parameters: .empty) { _, _ in throw TestFailure() },
        AppCommand(counter, parameters: .empty) { _, _ in
            count += 1
            return Echo(name: "counter", count: count)
        }
    ]
}

struct TestHost {
    let host: AgentHost
    let bundleId: String

    static func start(
        allowMutations: Bool = false, limits: AgentHostConfiguration.Limits = .init(),
        onError: (@Sendable (any Error) -> Failure?)? = nil
    ) async throws -> TestHost {
        let bundleId = "dev.agentdevkit.tests." + UUID().uuidString
        let host = AgentHost(
            catalog: AgentCatalog(scopes: [], commands: TestCommands.all), allowMutations: allowMutations,
            configuration: AgentHostConfiguration(
                limits: limits, identity: .fixed(bundleId: bundleId, buildFingerprint: "test-build"), onError: onError
            )
        )
        try await host.start()
        return TestHost(host: host, bundleId: bundleId)
    }

    /// Runs `body` with a live host and always awaits `stop()`, so no session directory outlives the test.
    static func run(
        allowMutations: Bool = false, limits: AgentHostConfiguration.Limits = .init(),
        onError: (@Sendable (any Error) -> Failure?)? = nil, _ body: (TestHost) async throws -> Void
    ) async throws {
        let test = try await start(allowMutations: allowMutations, limits: limits, onError: onError)
        do { try await body(test) } catch {
            await test.stop()
            throw error
        }
        await test.stop()
    }

    func client() throws -> AgentClient { try AgentClient(session: bundleId) }

    func descriptor() throws -> SessionDescriptor {
        try #require(SessionDirectory.discover(.local).first { $0.identity.bundleId == bundleId })
    }

    var socketPath: String {
        get throws { try SessionDirectory(id: descriptor().identity.sessionId).socketPath }
    }

    /// Sends one request with explicit envelope fields and returns the decoded response.
    func raw(
        method: String = SystemMethod.hello.rawValue, params: [String: Any] = [:],
        version: String = Wire.version, auth: String? = nil, requestId: UUID = UUID()
    ) async throws -> Response<JSONValue> {
        let session = try descriptor()
        let envelope: [String: Any] = [
            "protocol": version, "requestId": requestId.uuidString, "sessionId": session.identity.sessionId.uuidString,
            "auth": auth ?? session.auth, "method": method, "params": params, "timeoutMs": 1_000
        ]
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        return try await exchange(payload)
    }

    func exchange(_ payload: Data) async throws -> Response<JSONValue> {
        let data = try await LocalSocket.exchange(payload, path: socketPath, expectedPID: getpid(), timeoutMs: 1_500)
        return try JSONDecoder().decode(Response<JSONValue>.self, from: data)
    }

    func stop() async { await host.stop() }
}

private func failure(_ body: () async throws -> some Any) async -> Failure? {
    do {
        _ = try await body()
        return nil
    } catch let failure as Failure {
        return failure
    } catch {
        return nil
    }
}

@Suite struct HostIntegrationTests {
    @Test func helloAndCapabilitiesReflectFixedIdentityAndReadOnlyScope() async throws {
        try await TestHost.run() { test in
            let client = try test.client()
            let hello = try #require(try await client.hello().result)
            #expect(hello.bundleId == test.bundleId)
            #expect(hello.buildFingerprint == "test-build")
            #expect(hello.pid == getpid())
            let capabilities = try #require(try await client.capabilities().result)
            #expect(capabilities.readOnly)
            #expect(capabilities.methods.contains("test.echo"))
            #expect(!capabilities.methods.contains("test.mutate"))
            #expect(await test.host.state == .running(hello))
        }
    }

    @Test func secondStartAndStopReportTypedState() async throws {
        let test = try await TestHost.start()
        await #expect(throws: AgentHostStartError.alreadyRunning) { try await test.host.start() }
        await test.stop()
        #expect(await test.host.state == .stopped)
        #expect(try SessionDirectory.discover(.local).allSatisfy { $0.identity.bundleId != test.bundleId })
    }

    @Test func wrongCredentialsAreRejectedWithoutConsumingTheAuthenticatedBudget() async throws {
        try await TestHost.run(limits: .init(requestsPerSecond: 50, rejectedRequestsPerSecond: 2)) { test in
            var codes: [Failure.Code] = []
            for _ in 0..<5 {
                let response = try await test.raw(auth: String(repeating: "A", count: 44))
                #expect(!response.ok)
                #expect(response.requestId == nil, "An unauthenticated request must not echo its request ID.")
                codes.append(try #require(response.error?.code))
            }
            #expect(codes.first == .authRequired)
            #expect(codes.contains(.rateLimited))
            #expect(codes.allSatisfy { $0 == .authRequired || $0 == .rateLimited })
            let hello = try await test.raw()
            #expect(hello.ok)
        }
    }

    @Test func unsupportedProtocolVersionIsRejected() async throws {
        try await TestHost.run() { test in
            let response = try await test.raw(version: "agentdevkit/999")
            #expect(response.error?.code == .unsupportedVersion)
        }
    }

    @Test func repeatedRequestIdReplaysTheOriginalResponse() async throws {
        try await TestHost.run(allowMutations: true) { test in
            let client = try test.client()
            let id = UUID()
            let first = try await client.call(TestCommands.counter, EmptyParameters(), requestId: id)
            let retry = try await client.call(TestCommands.counter, EmptyParameters(), requestId: id)
            #expect(first.result?.count == retry.result?.count, "A retry must not run the mutation again.")
            let next = try await client.call(TestCommands.counter, EmptyParameters())
            #expect(next.result?.count == (first.result?.count ?? 0) + 1)
            // The same ID with different params is a client error, not a replay.
            let reused = try await test.raw(method: "test.echo", params: ["name": "x"], requestId: id)
            #expect(reused.error?.code == .conflict)
        }
    }

    @Test func authenticatedResponsesCarryTheSessionIdentity() async throws {
        try await TestHost.run() { test in
            let identity = try test.descriptor().identity
            let ok = try await test.raw()
            #expect(ok.sessionId == identity.sessionId)
            #expect(ok.pid == identity.pid)
            let failed = try await test.raw(method: "missing.method")
            #expect(failed.error?.code == .unknownMethod)
            #expect(failed.sessionId == identity.sessionId)
            let unauthenticated = try await test.raw(auth: String(repeating: "B", count: 44))
            #expect(unauthenticated.sessionId == nil, "Unauthenticated failures reveal no session identity.")
        }
    }

    @Test func clientReportsSelectorErrorsWithDistinctCodes() async throws {
        let missing = await failure { try AgentClient(session: "dev.agentdevkit.tests.none." + UUID().uuidString) }
        #expect(missing?.code == .sessionNotFound)
        #expect(missing?.code.exitCode == 3)
        let shared = "dev.agentdevkit.tests.shared." + UUID().uuidString
        let hosts = [
            AgentHost(configuration: .init(identity: .fixed(bundleId: shared, buildFingerprint: "a"))),
            AgentHost(configuration: .init(identity: .fixed(bundleId: shared, buildFingerprint: "b")))
        ]
        for host in hosts { try await host.start() }
        let ambiguous = await failure { try AgentClient(session: shared) }
        #expect(ambiguous?.code == .ambiguousSession)
        #expect(ambiguous?.details?["sessionIds"]?.arrayValue?.count == 2)
        for host in hosts { await host.stop() }
        let ended = await failure { try AgentClient(session: shared) }
        #expect(ended?.code == .sessionNotFound)
    }

    @Test func oversizedRequestFrameIsRejected() async throws {
        try await TestHost.run() { test in
            let response = try await test.raw(method: "test.echo", params: ["name": String(repeating: "n", count: 5_000)])
            #expect(response.error?.code == .frameTooLarge)
        }
    }

    @Test func invalidParametersNameTheFailingField() async throws {
        try await TestHost.run() { test in
            let mistyped = try await test.raw(method: "test.echo", params: ["name": 5])
            #expect(mistyped.error?.code == .invalidParams)
            #expect(mistyped.error?.details?["field"] == "name")
            let unexpected = try await test.raw(method: "test.echo", params: ["name": "a", "extra": true])
            #expect(unexpected.error?.details?["field"] == "extra")
            let missing = try await test.raw(method: "test.echo", params: ["count": 1])
            #expect(missing.error?.details?["field"] == "name")
            let echoed = try await test.client().call(TestCommands.echo, Echo(name: "a", count: 2))
            #expect(echoed.result?.count == 2)
        }
    }

    @Test func authenticatedRequestsAreRateLimited() async throws {
        try await TestHost.run(limits: .init(requestsPerSecond: 2)) { test in
            var codes: [Failure.Code?] = []
            for _ in 0..<7 { codes.append(try await test.raw().error?.code) }
            #expect(codes.contains(nil))
            #expect(codes.contains(.rateLimited))
        }
    }

    @Test func readOnlySessionDeniesMutationAndMutationSessionAllowsIt() async throws {
        try await TestHost.run() { readOnly in
            let denied = try await readOnly.raw(method: "test.mutate")
            #expect(denied.error?.code == .permissionDenied)

            try await TestHost.run(allowMutations: true) { mutable in
                let mutated = try await mutable.client().call(TestCommands.mutate, EmptyParameters())
                #expect(mutated.result?.name == "mutated")
                let capabilities = try await mutable.client().capabilities()
                #expect(capabilities.result?.readOnly == false)
            }
        }
    }

    @Test func oversizedResponseReturnsTypedError() async throws {
        try await TestHost.run(limits: .init(maxResponseBytes: 2_048)) { test in
            let error = await failure { try await test.client().call(TestCommands.large, EmptyParameters()) }
            #expect(error?.code == .responseTooLarge)
            #expect(error?.details?["limitBytes"] == 2048)
        }
    }

    @Test func unknownErrorsReportTypeOrAppMapping() async throws {
        try await TestHost.run() { plain in
            let unmapped = await failure { try await plain.client().call(TestCommands.fail, EmptyParameters()) }
            #expect(unmapped?.code == .internalError)
            #expect(unmapped?.details?["errorType"] == "TestFailure")

            try await TestHost.run(onError: { _ in Failure(.notReady, "Mapped.") }) { mapped in
                let error = await failure { try await mapped.client().call(TestCommands.fail, EmptyParameters()) }
                #expect(error?.code == .notReady)
            }
        }
    }

    @Test func truncatedAndIdlePeersReleaseTheirConnection() async throws {
        try await TestHost.run(limits: .init(maxConnections: 1, requestReadTimeoutMs: 100)) { test in
            let path = try test.socketPath
            let clock = ContinuousClock()
            // One worker and a one-entry backlog: each stalled peer must be dropped at the read deadline.
            for stalled in [Data([0, 0, 0, 100]) + Data("partial".utf8), Data()] {
                let peer = try connectRaw(path)
                defer { close(peer) }
                _ = stalled.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
                try await Task.sleep(for: .milliseconds(30))
                let start = clock.now
                #expect(try await test.raw().ok)
                #expect(start.duration(to: clock.now) < .seconds(1))
            }
        }
    }

    @Test func staleDescriptorIsNotDiscovered() async throws {
        let bundleId = "dev.agentdevkit.tests.stale." + UUID().uuidString
        let id = UUID()
        let directory = try SessionDirectory(id: id)
        try directory.create()
        defer { directory.remove() }
        let listener = try LocalListener(path: directory.socketPath)
        defer { listener.close() }
        // The live PID with a different start time models a crashed instance whose PID was reused.
        let identity = SessionIdentity(sessionId: id, bundleId: bundleId, pid: getpid(),
                                       launchedAt: Date(timeIntervalSince1970: 1), buildFingerprint: "stale")
        try directory.publish(SessionDescriptor(identity: identity, auth: String(repeating: "A", count: 44)))
        #expect(try SessionDirectory.discover(.local).allSatisfy { $0.identity.sessionId != id })
        let error = await failure { try AgentClient(session: bundleId) }
        #expect(error?.code == .sessionNotFound)
    }
}

private func connectRaw(_ path: String) throws -> Int32 {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init(bitPattern:))) }
    let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count)
    address.sun_len = UInt8(length)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
    }
    guard socket >= 0, result == 0 else { Issue.record("connect errno \(errno)"); throw TestFailure() }
    return socket
}
