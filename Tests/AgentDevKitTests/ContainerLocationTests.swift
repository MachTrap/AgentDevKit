import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import AgentDevKitTransport
import Foundation
import Testing

@Suite struct ContainerLocationTests {
    /// A fake home with the container layout a sandboxed app gets from containermanagerd.
    private func withContainer(_ body: (String, URL) async throws -> Void) async throws {
        let home = URL(fileURLWithPath: "/tmp/adk-home-" + UUID().uuidString.prefix(8), isDirectory: true)
        let bundleId = "dev.agentdevkit.tests.box" + UUID().uuidString.prefix(6)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Containers/\(bundleId)/Data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try await SessionDirectory.$homeOverride.withValue(home) { try await body(bundleId, home) }
    }

    @Test func containerSessionIsFoundByBundleIdWithoutExtraConfiguration() async throws {
        try await withContainer { bundleId, home in
            let host = AgentHost(configuration: .init(identity: .fixed(bundleId: bundleId, buildFingerprint: "box")))
            try await host.start(at: .appContainer(bundleId))
            defer { Task { await host.stop() } }

            let root = home.appendingPathComponent("Library/Containers/\(bundleId)/Data/a")
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.count == 1 && entries[0].count == 16, "Container sessions use a short directory name.")
            let socket = root.appendingPathComponent(entries[0]).appendingPathComponent("s").path
            #expect(socket.utf8.count < 104)

            // The default location finds a sandboxed app's session from its bundle ID alone.
            let hello = try await AgentClient(session: bundleId).hello()
            #expect(hello.result?.bundleId == bundleId)
            #expect(try AgentClient.sessions(at: .appContainer(bundleId)).count == 1)
            #expect(try AgentClient.sessions().allSatisfy { $0.bundleId != bundleId }, "Containers are not scanned by default.")
            await host.stop()
            #expect(try AgentClient.sessions(at: .appContainer(bundleId)).isEmpty)
        }
    }

    @Test func unknownContainerIsNotFoundAndInvalidIdentifiersAreRejected() async throws {
        try await withContainer { bundleId, _ in
            let missing = await #expect(throws: Failure.self) { try AgentClient(session: bundleId) }
            #expect(missing?.code == .sessionNotFound)
            for invalid in ["../escape", "a/b", ""] {
                #expect(throws: Failure.self) { try AgentClient.sessions(at: .appContainer(invalid)) }
            }
        }
    }
}
