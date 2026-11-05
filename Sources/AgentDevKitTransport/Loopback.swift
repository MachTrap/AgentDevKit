import AgentDevKitCore
import CryptoKit
import Dispatch
import Foundation
import Network
import Security
import os

package enum Loopback {
    fileprivate static let queue = DispatchQueue(label: "AgentDevKit.loopback")
    fileprivate static let address = IPv4Address("127.0.0.1")!

    fileprivate static func tls() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        return options
    }

    package static func exchange(_ payload: Data, port: UInt16, pin: Data, timeoutMs: Int) async throws -> Data {
        let tls = tls()
        let pinRejected = OSAllocatedUnfairLock(initialState: false)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetNetworkFetchAllowed(trust, false)
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            let matches = leaf.map { certificatePin($0) == pin } ?? false
            if !matches { pinRejected.withLock { $0 = true } }
            complete(matches)
        }, queue)
        let connection = NWConnection(
            host: .ipv4(address), port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        defer { connection.cancel() }
        do {
            let response = try await timed(milliseconds: timeoutMs) {
                try await withTaskCancellationHandler {
                    do { try await connect(connection) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw pinRejected.withLock { $0 } ? SocketError.peerMismatch : SocketError.connectFailed }
                    try await send(payload, connection)
                    return try await frame(connection, limit: Wire.maxFrameBytes)
                } onCancel: { connection.cancel() }
            }
            try Task.checkCancellation()
            return response
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    fileprivate static func certificatePin(_ certificate: SecCertificate) -> Data {
        Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    private static func connect(_ connection: NWConnection) async throws {
        let (states, stream) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: stream.yield(true); stream.finish()
            case .failed, .cancelled, .waiting: stream.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        for await ready in states where ready { return }
        try Task.checkCancellation()
        throw SocketError.disconnected
    }

    fileprivate static func timed<T: Sendable>(
        milliseconds: Int, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .milliseconds(milliseconds))
                throw SocketError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SocketError.disconnected }
            return result
        }
    }

    fileprivate static func receive(_ connection: NWConnection, count: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: SocketError.disconnected) }
            }
        }
    }

    fileprivate static func frame(_ connection: NWConnection, limit: Int) async throws -> Data {
        let header = try await receive(connection, count: 4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0 else { throw SocketError.emptyFrame }
        guard size <= limit else { throw SocketError.oversized }
        return try await receive(connection, count: size)
    }

    fileprivate static func send(_ payload: Data, _ connection: NWConnection) async throws {
        guard !payload.isEmpty else { throw SocketError.emptyFrame }
        guard payload.count <= Wire.maxFrameBytes else { throw SocketError.oversized }
        var size = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

package final class LoopbackListener: Sendable {
    private let listener: NWListener
    private struct Admission: Sendable {
        var closed = false
        var active: [ObjectIdentifier: NWConnection] = [:]
    }

    private let connections = OSAllocatedUnfairLock(initialState: Admission())
    private let workers = DispatchGroup()
    private let limits: ListenerLimits
    package let pin: Data

    package init(identity: SecIdentity, limits: ListenerLimits = ListenerLimits()) throws {
        self.limits = limits
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate, let networkIdentity = sec_identity_create(identity)
        else { throw SocketError.system }
        pin = Loopback.certificatePin(certificate)
        let tls = Loopback.tls()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(Loopback.address), port: .any)
        listener = try NWListener(using: params)
    }

    package func start(
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @escaping @Sendable (Failure) -> Data
    ) async throws -> UInt16 {
        let limits = limits
        listener.newConnectionHandler = { [weak self] connection in
            guard let self,
                  case .hostPort(host: .ipv4(Loopback.address), port: _) = connection.endpoint
            else { connection.cancel(); return }
            let key = ObjectIdentifier(connection)
            let admitted = connections.withLock { admission in
                guard !admission.closed, admission.active.count < limits.connections else { return false }
                admission.active[key] = connection
                workers.enter()
                return true
            }
            guard admitted else { connection.cancel(); return }
            let acceptedAt = DispatchTime.now()
            connection.start(queue: Loopback.queue)
            Task {
                defer {
                    connection.cancel()
                    self.connections.withLock { $0.active[key] = nil }
                    self.workers.leave()
                }
                try? await Loopback.timed(milliseconds: limits.connectionTimeoutMs) {
                    try await withTaskCancellationHandler {
                        try await Self.serve(connection, acceptedAt: acceptedAt, limits: limits, handle: handle, reject: reject)
                    } onCancel: { connection.cancel() }
                }
            }
        }
        let (states, stream) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: stream.yield(true); stream.finish()
            case .failed, .cancelled, .waiting: stream.finish()
            default: break
            }
        }
        listener.start(queue: Loopback.queue)
        return try await Loopback.timed(milliseconds: Wire.maxTimeoutMs) {
            for await ready in states where ready {
                if let port = self.listener.port, port != .any { return port.rawValue }
            }
            try Task.checkCancellation()
            throw SocketError.system
        }
    }

    package func close() {
        listener.cancel()
        let active = connections.withLock { admission in
            admission.closed = true
            return Array(admission.active.values)
        }
        for connection in active { connection.cancel() }
    }

    package func drain() async {
        await withCheckedContinuation { continuation in
            workers.notify(queue: Loopback.queue) { continuation.resume() }
        }
    }

    private static func serve(
        _ connection: NWConnection, acceptedAt: DispatchTime, limits: ListenerLimits,
        handle: @escaping @Sendable (Data, DispatchTime) async -> Data,
        reject: @Sendable (Failure) -> Data
    ) async throws {
        let payload: Data
        // The TLS handshake and request frame share the read budget, so an idle peer releases its slot early.
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - acceptedAt.uptimeNanoseconds) / 1_000_000)
        let readBudget = max(1, limits.readTimeoutMs - elapsedMs)
        let maxRequestBytes = limits.maxRequestBytes
        do {
            payload = try await Loopback.timed(milliseconds: readBudget) {
                try await Loopback.frame(connection, limit: maxRequestBytes)
            }
        } catch SocketError.oversized {
            return try await Loopback.send(reject(Failure(.frameTooLarge, "Request frame exceeds the limit.")), connection)
        } catch SocketError.emptyFrame {
            return try await Loopback.send(reject(Failure(.invalidParams, "Request frame is empty.")), connection)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let reply = await handle(payload, acceptedAt)
                try Task.checkCancellation()
                try await Loopback.send(reply, connection)
            }
            group.addTask { _ = try await Loopback.receive(connection, count: 1) }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            _ = try await group.next()
        }
    }
}
