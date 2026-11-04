import Darwin
import Foundation

/// A testing-target-only file store. Profiles use UUIDs and have a single writer.
final class TestingWorkspace {
    private let document: URL
    private let lock: Int32

    init(arguments: [String]) throws {
        let profile: UUID
        if let index = arguments.firstIndex(of: "--agentdevkit-profile") {
            guard index + 1 < arguments.count, let parsed = UUID(uuidString: arguments[index + 1]) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            profile = parsed
        } else {
            profile = UUID()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentLab-Testing", isDirectory: true)
        let directory = root.appendingPathComponent(profile.uuidString, isDirectory: true)
        try Self.secureDirectory(root)
        try Self.secureDirectory(directory)
        document = directory.appendingPathComponent("workspace.json")
        let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o777) == (S_IFREG | 0o600),
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        lock = fd
    }

    deinit { close(lock) }

    func load() throws -> Workspace? {
        let fd = open(document.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1_048_576,
              let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    func save(_ workspace: Workspace) throws {
        try JSONEncoder().encode(workspace).write(to: document, options: .atomic)
    }

    private static func secureDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o777) == (S_IFDIR | 0o700) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
