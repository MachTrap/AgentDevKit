import AgentDevKitCore
import Darwin
import Dispatch
import Foundation

/// The host owns this listener and runs it once. The descriptor is closed
/// after the structured worker group exits, so a worker cannot poll a reused fd.
package struct LocalListener: Sendable {
    package static let concurrentConnections = 4

    private let socket: Int32

    package init(path: String) throws {
        let socket = try LocalSocket.makeSocket()
        do {
            guard try LocalSocket.withAddress(path, { Darwin.bind(socket, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0,
                  Darwin.listen(socket, Int32(Self.concurrentConnections)) == 0
            else { throw SocketError.system }
        } catch {
            Darwin.close(socket)
            throw error
        }
        self.socket = socket
    }

    package func close() {
        Darwin.close(socket)
    }

    package func run(
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @escaping @Sendable (Failure) -> Data
    ) async {
        defer { close() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.concurrentConnections {
                group.addTask {
                    await serveConnections(handle: handle, reject: reject)
                }
            }
        }
    }

    private func serveConnections(
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @escaping @Sendable (Failure) -> Data
    ) async {
        while !Task.isCancelled {
            do {
                let peer = try await LocalSocket.offload {
                    try LocalSocket.wait(socket, for: Int16(POLLIN), until: .now() + .milliseconds(200))
                    return Darwin.accept(socket, nil, nil)
                }
                if peer >= 0 {
                    await serve(peer, handle: handle, reject: reject)
                }
            } catch SocketError.timedOut {
                continue
            } catch {
                return
            }
        }
    }

    private func serve(
        _ peer: Int32, handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @Sendable (Failure) -> Data
    ) async {
        defer { Darwin.close(peer) }
        guard !Task.isCancelled else { return }
        let acceptedAt = DispatchTime.now()
        let deadline = acceptedAt + .milliseconds(Wire.maxTimeoutMs)
        do {
            try LocalSocket.configure(peer)
            try LocalSocket.verifyPeer(peer)

            let response: Data
            do {
                let payload = try await LocalSocket.offload {
                    try LocalSocket.readFrame(peer, maxBytes: Wire.maxRequestBytes, until: deadline)
                }
                guard !Task.isCancelled else { return }
                guard let reply = await handleWhileConnected(peer, payload: payload, acceptedAt: acceptedAt, handle: handle) else { return }
                response = reply
            } catch SocketError.oversized {
                response = reject(Failure(.frameTooLarge, "Request frame exceeds the limit."))
            } catch SocketError.emptyFrame {
                response = reject(Failure(.invalidParams, "Request frame is empty."))
            }

            try await LocalSocket.offload {
                try LocalSocket.writeFrame(response, to: peer, until: deadline)
            }
        } catch {
            // A stalled, interrupted or foreign peer owns only this connection.
        }
    }

    private func handleWhileConnected(
        _ peer: Int32, payload: Data, acceptedAt: DispatchTime,
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data
    ) async -> Data? {
        // The read source owns a duplicate. Its asynchronous cancel handler
        // can close that descriptor independently of the connection worker.
        let watchedPeer = fcntl(peer, F_DUPFD_CLOEXEC, 0)
        guard watchedPeer >= 0 else { return nil }
        let (activity, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeReadSource(fileDescriptor: watchedPeer)
        source.setEventHandler {
            // Once the full request is read, additional bytes or EOF both
            // terminate the one-request connection.
            signal.yield(())
            signal.finish()
        }
        source.setCancelHandler {
            Darwin.close(watchedPeer)
            signal.finish()
        }
        source.activate()
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { await handle(payload, acceptedAt) }
            group.addTask {
                var iterator = activity.makeAsyncIterator()
                _ = await iterator.next()
                return nil
            }
            defer {
                group.cancelAll()
                source.cancel()
            }
            return await group.next() ?? nil
        }
    }

}
