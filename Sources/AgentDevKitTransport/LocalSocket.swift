import AgentDevKitCore
import Darwin
import Dispatch
import Foundation
import os

package enum SocketError: Error {
    case system
    case disconnected
    case timedOut
    case oversized
    case emptyFrame
    case pathTooLong
    /// No listener accepted the connection.
    case connectFailed
    /// The connected peer is not the expected process, user or certificate.
    case peerMismatch
}

package enum LocalSocket {
    private static let ioQueue = DispatchQueue(label: "AgentDevKit.socket", qos: .userInitiated, attributes: .concurrent)

    static func offload<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }

    static func makeSocket() throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SocketError.system }
        do {
            try configure(socket)
            return socket
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    static func configure(_ socket: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(socket, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw SocketError.system }
    }

    static func withAddress<Value>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Value
    ) throws -> Value {
        var address = sockaddr_un()
        let pathBytes = path.utf8CString
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        let length = pathOffset + pathBytes.count
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes.map(UInt8.init(bitPattern:))) }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(length))
            }
        }
    }

    static func verifyPeer(_ socket: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == geteuid() else {
            throw SocketError.disconnected
        }
    }

    static func wait(_ socket: Int32, for event: Int16, until deadline: DispatchTime) throws {
        var descriptor = pollfd(fd: socket, events: event, revents: 0)
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { throw SocketError.timedOut }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let milliseconds = Int32((remaining + 999_999) / 1_000_000)
            let ready = Darwin.poll(&descriptor, 1, milliseconds)
            if ready > 0 {
                // A read can still return buffered data when POLLHUP is present.
                if descriptor.revents & event != 0 { return }
                throw SocketError.disconnected
            }
            if ready == 0 { throw SocketError.timedOut }
            if errno != EINTR { throw SocketError.system }
        }
    }

    static func readFrame(_ socket: Int32, maxBytes: Int, until deadline: DispatchTime) throws -> Data {
        let header = try read(socket, count: 4, until: deadline)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0 else { throw SocketError.emptyFrame }
        guard length <= maxBytes else { throw SocketError.oversized }
        return try read(socket, count: length, until: deadline)
    }

    static func writeFrame(_ data: Data, to socket: Int32, until deadline: DispatchTime) throws {
        guard !data.isEmpty else { throw SocketError.emptyFrame }
        guard data.count <= Wire.maxFrameBytes else { throw SocketError.oversized }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try write($0, to: socket, until: deadline) }
        try data.withUnsafeBytes { try write($0, to: socket, until: deadline) }
    }

    private static func read(_ socket: Int32, count: Int, until deadline: DispatchTime) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(socket, for: Int16(POLLIN), until: deadline)
                let result = Darwin.recv(socket, buffer.baseAddress! + offset, count - offset, 0)
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    throw SocketError.disconnected
                } else if errno != EINTR && errno != EAGAIN {
                    throw SocketError.system
                }
            }
        }
        return data
    }

    private static func write(_ buffer: UnsafeRawBufferPointer, to socket: Int32, until deadline: DispatchTime) throws {
        var offset = 0
        while offset < buffer.count {
            try wait(socket, for: Int16(POLLOUT), until: deadline)
            let result = Darwin.send(socket, buffer.baseAddress! + offset, buffer.count - offset, 0)
            if result > 0 {
                offset += result
            } else if result == 0 || (errno != EINTR && errno != EAGAIN) {
                throw SocketError.disconnected
            }
        }
    }

    package static func exchange(_ payload: Data, path: String, expectedPID: Int32, timeoutMs: Int) async throws -> Data {
        try Task.checkCancellation()
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let handle = FileHandle(fileDescriptor: try makeSocket(), closeOnDealloc: true)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let response = try await offload {
                    let socket = handle.fileDescriptor
                    if cancelled.withLock({ $0 }) { throw CancellationError() }
                    do { try connect(socket, path: path, until: deadline) }
                    catch SocketError.timedOut { throw SocketError.timedOut }
                    catch { throw SocketError.connectFailed }
                    if cancelled.withLock({ $0 }) { throw CancellationError() }
                    do { try verifyPeer(socket) } catch { throw SocketError.peerMismatch }
                    var peerPID: pid_t = 0
                    var peerLength = socklen_t(MemoryLayout<pid_t>.size)
                    guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerLength) == 0,
                          peerPID == expectedPID else { throw SocketError.peerMismatch }
                    try writeFrame(payload, to: socket, until: deadline)
                    return try readFrame(socket, maxBytes: Wire.maxFrameBytes, until: deadline)
                }
                try Task.checkCancellation()
                return response
            } onCancel: {
                cancelled.withLock { $0 = true }
                _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func connect(_ socket: Int32, path: String, until deadline: DispatchTime) throws {
        let result = try withAddress(path) { Darwin.connect(socket, $0, $1) }
        guard result != 0 else { return }
        guard errno == EINPROGRESS else { throw SocketError.system }
        try wait(socket, for: Int16(POLLOUT), until: deadline)
        var pendingError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &pendingError, &length) == 0,
              pendingError == 0 else { throw SocketError.system }
    }
}
