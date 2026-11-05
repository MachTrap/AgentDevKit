import AgentDevKitCore
import Darwin
import Dispatch
import Foundation
import os

/// Per-connection bounds shared by the Unix and loopback listeners.
package struct ListenerLimits: Sendable {
    package var connections: Int
    package var maxRequestBytes: Int
    package var readTimeoutMs: Int
    /// Upper bound for one connection, from accept to the written response.
    package var connectionTimeoutMs: Int

    package init(connections: Int = 4, maxRequestBytes: Int = Wire.maxRequestBytes, readTimeoutMs: Int = Wire.maxTimeoutMs,
                 connectionTimeoutMs: Int = Wire.maxTimeoutMs) {
        self.connections = connections
        self.maxRequestBytes = maxRequestBytes
        self.readTimeoutMs = readTimeoutMs
        self.connectionTimeoutMs = connectionTimeoutMs
    }
}

/// The host owns this listener and runs it once. The descriptor is closed
/// after the structured worker group exits, so a worker cannot poll a reused fd.
package struct LocalListener: Sendable {
    private static let log = Logger(subsystem: "dev.agentdevkit", category: "transport")
    private let socket: Int32
    private let limits: ListenerLimits

    package init(path: String, limits: ListenerLimits = ListenerLimits()) throws {
        let socket = try LocalSocket.makeSocket()
        do {
            guard try LocalSocket.withAddress(path, { Darwin.bind(socket, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0,
                  Darwin.listen(socket, Int32(limits.connections)) == 0
            else { throw SocketError.system }
        } catch {
            Darwin.close(socket)
            throw error
        }
        self.socket = socket
        self.limits = limits
    }

    package func close() {
        Darwin.close(socket)
    }

    /// Accepts connections from a dispatch read source and serves at most `limits.connections`
    /// at a time. No thread blocks while the listener is idle. While every slot is busy the source
    /// stays suspended, so further peers wait in the kernel backlog instead of being dropped.
    package func run(
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @escaping @Sendable (Failure) -> Data
    ) async {
        let (readable, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: Self.acceptQueue)
        let gate = SourceGate(source)
        source.setEventHandler {
            gate.suspend()
            signal.yield()
        }
        let listener = socket
        // Dispatch may still watch the descriptor until its cancel handler runs, so close it there.
        source.setCancelHandler {
            Darwin.close(listener)
            signal.finish()
        }
        source.activate()
        let connections = limits.connections
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for await _ in readable {
                    // Drain the backlog up to capacity, then re-arm the source.
                    while !Task.isCancelled {
                        if running >= connections {
                            await group.next()
                            running -= 1
                            continue
                        }
                        let peer = Darwin.accept(listener, nil, nil)
                        guard peer >= 0 else { break }
                        running += 1
                        group.addTask { await serve(peer, handle: handle, reject: reject) }
                    }
                    if Task.isCancelled { break }
                    gate.resume()
                }
                group.cancelAll()
            }
        } onCancel: {
            gate.cancel()
        }
        gate.cancel()
    }

    private static let acceptQueue = DispatchQueue(label: "AgentDevKit.accept")

    private func serve(
        _ peer: Int32, handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @Sendable (Failure) -> Data
    ) async {
        defer { Darwin.close(peer) }
        guard !Task.isCancelled else { return }
        let acceptedAt = DispatchTime.now()
        let deadline = acceptedAt + .milliseconds(limits.connectionTimeoutMs)
        let readTimeout = DispatchTimeInterval.milliseconds(limits.readTimeoutMs)
        let maxRequestBytes = limits.maxRequestBytes
        do {
            try LocalSocket.configure(peer)
            try LocalSocket.verifyPeer(peer)

            let response: Data
            do {
                // The read budget starts when an I/O thread begins reading, not when the
                // connection was accepted, so queueing delay never penalizes a prompt client.
                let payload = try await LocalSocket.offload {
                    try LocalSocket.readFrame(peer, maxBytes: maxRequestBytes, until: min(.now() + readTimeout, deadline))
                }
                guard !Task.isCancelled else { return }
                guard let reply = await handleWhileConnected(peer, payload: payload, acceptedAt: acceptedAt, handle: handle) else { return }
                response = reply
            } catch SocketError.oversized {
                response = reject(Failure(.frameTooLarge, "Request frame exceeds the limit."))
            } catch SocketError.emptyFrame {
                response = reject(Failure(.invalidParams, "Request frame is empty."))
            }

            do {
                try await LocalSocket.offload {
                    try LocalSocket.writeFrame(response, to: peer, until: deadline)
                }
            } catch {
                // The host bounds response size, so a write failure means the peer stalled or left.
                Self.log.info("response write failed: \(String(describing: error), privacy: .public)")
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

/// Balances suspend and resume on a dispatch source, and resumes before cancelling,
/// because a suspended source never runs its cancel handler.
private final class SourceGate: @unchecked Sendable {
    private let source: any DispatchSourceRead
    private let lock = NSLock()
    private var suspended = false
    private var cancelled = false

    init(_ source: any DispatchSourceRead) { self.source = source }

    func suspend() {
        lock.withLock {
            guard !suspended, !cancelled else { return }
            suspended = true
            source.suspend()
        }
    }

    func resume() {
        lock.withLock {
            guard suspended, !cancelled else { return }
            suspended = false
            source.resume()
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            source.cancel()
            if suspended {
                suspended = false
                source.resume()
            }
        }
    }
}
