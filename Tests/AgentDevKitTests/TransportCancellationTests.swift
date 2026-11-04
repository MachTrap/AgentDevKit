import AgentDevKitTransport
import Darwin
import Foundation
import Testing

@Test func clientCancellationReachesRunningSocketHandler() async throws {
    let directory = URL(fileURLWithPath: "/tmp/adk-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s").path
    let listener = try LocalListener(path: path)
    let (starts, start) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let (finishes, finish) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    let server = Task {
        await listener.run { _, _ in
            start.yield(())
            do {
                try await Task.sleep(for: .milliseconds(1_600))
                finish.yield(false)
            } catch {
                finish.yield(Task.isCancelled)
            }
            finish.finish()
            return Data([0])
        } reject: { _ in Data([0]) }
    }
    let request = Task {
        try await LocalSocket.exchange(Data([1]), path: path, expectedPID: getpid(), timeoutMs: 2_000)
    }
    // A bounded fallback prevents a connection regression from hanging the suite.
    let fallback = Task {
        try? await Task.sleep(for: .seconds(3))
        start.finish()
        finish.finish()
    }
    var startIterator = starts.makeAsyncIterator()
    let received = await startIterator.next() != nil
    #expect(received)
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    var finishIterator = finishes.makeAsyncIterator()
    #expect(await finishIterator.next() == true)
    fallback.cancel()
    server.cancel()
    await server.value
}
