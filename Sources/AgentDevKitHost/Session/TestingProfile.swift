import Darwin
import Foundation

/// Isolated, single-writer storage for a Testing build. Each profile is a 0700 directory
/// under the user's temporary directory, locked for the lifetime of this object.
/// Never point it at the app's ordinary user data.
public final class TestingProfile {
    public enum ProfileError: Error, Sendable, Equatable {
        case insecureDirectory
        case locked
        case invalidName
        case tooLarge
        case unreadable
    }

    public let id: UUID
    public let directory: URL
    private let lock: Int32

    /// Opens or creates a profile. Pass the `--agentdevkit-profile` UUID to reopen one; nil creates a fresh profile.
    public init(appName: String, profile: UUID? = nil) throws {
        guard Self.validName(appName) else { throw ProfileError.invalidName }
        id = profile ?? UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(appName)-Testing", isDirectory: true)
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.secureDirectory(root)
        try Self.secureDirectory(directory)
        let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileError.insecureDirectory }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & (S_IFMT | 0o777) == (S_IFREG | 0o600) else {
            close(fd)
            throw ProfileError.insecureDirectory
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProfileError.locked
        }
        lock = fd
    }

    deinit { close(lock) }

    /// Reads a file in the profile without following links. Returns nil when it does not exist.
    public func read(_ name: String, maxBytes: Int = 1_048_576) throws -> Data? {
        let url = try file(name)
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProfileError.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw ProfileError.unreadable
        }
        guard info.st_size <= maxBytes, let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            throw ProfileError.tooLarge
        }
        return data
    }

    /// Replaces a file in the profile atomically.
    public func write(_ data: Data, to name: String) throws {
        try data.write(to: try file(name), options: .atomic)
    }

    /// A 0700 folder inside the profile for file-based fixtures, such as a generated home folder.
    /// Pass it to `FileTree.materialize(in:)` from `AgentDevKitFixtures`.
    public func fixtureDirectory(_ name: String) throws -> URL {
        let url = try file(name)
        try Self.secureDirectory(url)
        return url
    }

    private func file(_ name: String) throws -> URL {
        guard Self.validName(name), name != "lock" else { throw ProfileError.invalidName }
        return directory.appendingPathComponent(name)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func secureDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw ProfileError.insecureDirectory }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o777) == (S_IFDIR | 0o700) else { throw ProfileError.insecureDirectory }
    }
}
