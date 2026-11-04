import AgentDevKitCore
import Darwin
import Foundation
import Security

package struct SessionDescriptor: Codable, Sendable {
    package let identity: SessionIdentity
    package let auth: String
    package var port: UInt16?
    package var certificatePin: Data?

    package init(identity: SessionIdentity, auth: String) {
        self.identity = identity
        self.auth = auth
    }
}

package struct SessionDirectory: Sendable {
    private let url: URL
    private let source: SessionSource

    package init(id: UUID, source: SessionSource = .local) throws {
        self.source = source
        url = try Self.root(source).appendingPathComponent(Self.name(id, source), isDirectory: true)
    }

    private static func name(_ id: UUID, _ source: SessionSource) -> String {
        if case .appGroup = source { return String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)) }
        return id.uuidString
    }

    private static func root(_ source: SessionSource) throws -> URL {
        switch source {
        case .local:
            return try localRoot()
        case .appGroup(let identifier):
            guard !identifier.isEmpty,
                  let task = SecTaskCreateFromSelf(nil),
                  let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
                  groups.contains(identifier),
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            else { throw Failure(.sessionExpired, "App Group unavailable. Check signing team and App Group entitlement.") }
            return container.appendingPathComponent("a", isDirectory: true)
        case .pairingDirectory(let folder):
            do { try check(folder.path, type: S_IFDIR, mode: 0o700) }
            catch { throw Failure(.sessionExpired, "Pairing folder unavailable. Select an accessible folder owned by you with mode 0700.") }
            return folder.appendingPathComponent("adk", isDirectory: true)
        }
    }

    private static func localRoot() throws -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { throw SocketError.system }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else { throw SocketError.system }
        let bytes = buffer.dropLast().map(UInt8.init(bitPattern:))
        guard let path = String(bytes: bytes, encoding: .utf8) else { throw SocketError.system }
        let temp = URL(fileURLWithPath: path, isDirectory: true)
        try check(temp.path, type: S_IFDIR, mode: 0o700)
        return temp.appendingPathComponent("adk", isDirectory: true)
    }

    package var socketPath: String { url.appendingPathComponent("s").path }
    private var descriptorPath: String { url.appendingPathComponent("session.json").path }

    package func create() throws {
        let root = url.deletingLastPathComponent().path
        guard mkdir(root, 0o700) == 0 || errno == EEXIST else { throw SocketError.system }
        try Self.check(root, type: S_IFDIR, mode: 0o700)
        guard mkdir(url.path, 0o700) == 0 else { throw SocketError.system }
    }

    package func publish(_ descriptor: SessionDescriptor) throws {
        let staged = url.appendingPathComponent("pending").path
        let payload = try JSONEncoder().encode(descriptor)
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SocketError.system }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: payload)
        try file.close()
        guard rename(staged, descriptorPath) == 0 else { throw SocketError.system }
    }

    package func withdraw() {
        unlink(descriptorPath)
        if !source.isLoopback { unlink(socketPath) }
    }

    package func remove() {
        withdraw()
        unlink(url.appendingPathComponent("pending").path)
        rmdir(url.path)
    }

    package static func discover(_ source: SessionSource = .local) throws -> [SessionDescriptor] {
        let root = try root(source)
        var info = stat()
        if lstat(root.path, &info) == -1 && errno == ENOENT { return [] }
        try check(root.path, type: S_IFDIR, mode: 0o700)
        return try FileManager.default.contentsOfDirectory(atPath: root.path).compactMap { name in
            let directory = SessionDirectory(url: root.appendingPathComponent(name), source: source)
            return try? directory.read(name: name)
        }
    }

    private init(url: URL, source: SessionSource) {
        self.url = url
        self.source = source
    }

    private func read(name: String) throws -> SessionDescriptor {
        try Self.check(url.path, type: S_IFDIR, mode: 0o700)
        if !source.isLoopback { try Self.check(socketPath, type: S_IFSOCK, mode: 0o600) }
        let fd = open(descriptorPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SocketError.system }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, Self.matches(info, type: S_IFREG, mode: 0o600),
              (1...4096).contains(info.st_size),
              let data = try file.read(upToCount: 4097), data.count <= 4096
        else { throw SocketError.system }

        let descriptor = try JSONDecoder().decode(SessionDescriptor.self, from: data)
        guard Self.name(descriptor.identity.sessionId, source) == name,
              source.isLoopback
                ? (descriptor.port ?? 0) > 0 && descriptor.certificatePin?.count == 32
                : descriptor.port == nil && descriptor.certificatePin == nil,
              descriptor.auth.utf8.count == 44,
              Self.launchDate(pid: descriptor.identity.pid) == descriptor.identity.launchedAt
        else { throw SocketError.disconnected }
        return descriptor
    }

    package static func launchDate(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == geteuid() else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func check(_ path: String, type: mode_t, mode: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, matches(info, type: type, mode: mode) else { throw SocketError.system }
    }

    private static func matches(_ info: stat, type: mode_t, mode: mode_t) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == type && info.st_mode & 0o7777 == mode
    }
}


public enum SessionSource: Sendable {
    case local
    case appGroup(String)
    case pairingDirectory(URL)

    package var isLoopback: Bool {
        if case .pairingDirectory = self { return true }
        return false
    }
}
