import CryptoKit
import Darwin
import Foundation

/// A byte count for fixture files: `5.mb`, `512.kb`, `100.bytes`.
public struct ByteCount: Sendable, Hashable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let bytes: Int
    public init(_ bytes: Int) { self.bytes = max(0, bytes) }
    public init(integerLiteral value: Int) { self.init(value) }
    public var description: String { "\(bytes) bytes" }
}

extension Int {
    public var bytes: ByteCount { ByteCount(self) }
    public var kb: ByteCount { ByteCount(self * 1_024) }
    public var mb: ByteCount { ByteCount(self * 1_048_576) }
    public var gb: ByteCount { ByteCount(self * 1_073_741_824) }
}

/// How old an item's modification date is, relative to the materialization date.
public enum FileAge: Sendable, Hashable {
    case seconds(TimeInterval)
    case hours(Int)
    case days(Int)
    case date(Date)

    func date(relativeTo now: Date) -> Date {
        switch self {
        case .seconds(let seconds): now.addingTimeInterval(-seconds)
        case .hours(let hours): now.addingTimeInterval(-Double(hours) * 3_600)
        case .days(let days): now.addingTimeInterval(-Double(days) * 86_400)
        case .date(let date): date
        }
    }
}

/// A declarative file tree for Testing fixtures of file-based apps: seeded contents, aged dates, nested folders,
/// hard links, symbolic links, packages and duplicates. Link this product only into Testing targets.
///
/// ```swift
/// let tree = FileTree([
///     .file("Downloads/a.dmg", size: 5.mb, seed: 3, age: .days(300)),
///     .duplicate("Desktop/a copy.dmg", of: "Downloads/a.dmg"),
///     .hardLink("Documents/a-link.dmg", to: "Downloads/a.dmg"),
///     .package("Applications/Foo.app", bundleId: "com.example.foo"),
/// ])
/// let manifest = try tree.materialize(in: profile.fixtureDirectory("home"))
/// ```
public struct FileTree: Sendable {
    public enum Node: Sendable, Hashable {
        /// A regular file of `size` bytes. Contents come from a deterministic generator seeded with `seed`,
        /// or, without one, with the path, so the same tree always has the same bytes.
        case file(String, size: ByteCount = 0, seed: UInt64? = nil, age: FileAge? = nil)
        /// A file with exact contents.
        case text(String, contents: String, age: FileAge? = nil)
        case directory(String, age: FileAge? = nil)
        /// A second name for an existing file: same inode, same contents.
        case hardLink(String, to: String)
        /// A symbolic link whose target is stored as given.
        case symlink(String, to: String)
        /// A macOS bundle folder, `Foo.app/Contents/Info.plist` with `Contents/MacOS`.
        case package(String, bundleId: String? = nil, age: FileAge? = nil)
        /// A separate file with the same contents as another, as a duplicate finder would see it.
        case duplicate(String, of: String, age: FileAge? = nil)

        var path: String {
            switch self {
            case .file(let path, _, _, _), .text(let path, _, _), .directory(let path, _), .hardLink(let path, _),
                 .symlink(let path, _), .package(let path, _, _), .duplicate(let path, _, _): path
            }
        }
    }

    public enum TreeError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalidPath(String)
        case missingSource(String)
        case tooLarge(Int)
        case notEmpty(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .invalidPath(let path): "Fixture path \(path) must be relative and stay inside the root."
            case .missingSource(let path): "\(path) refers to an item the tree has not created."
            case .tooLarge(let bytes): "The tree would write \(bytes) bytes, more than its limit."
            case .notEmpty(let path): "\(path) is not empty. Pass replace: true to clear it first."
            case .system(let path, let code): "\(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public let nodes: [Node]
    /// The most bytes `materialize` writes. Defaults to 2 GiB.
    public var maxBytes: Int

    public init(_ nodes: [Node], maxBytes: Int = 2 * 1_073_741_824) {
        self.nodes = nodes
        self.maxBytes = maxBytes
    }

    /// Creates the tree under `root` and returns its manifest. `root` is created if needed and resolved with
    /// `realpath`, so `/var/…` becomes `/private/var/…` and recorded paths match what the app's file APIs report.
    /// `replace` removes existing contents of `root` first; otherwise a nonempty root is refused.
    public func materialize(in root: URL, now: Date = Date(), replace: Bool = false) throws -> FileTreeManifest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = try Self.canonical(root)
        let manager = FileManager.default
        let existing = try manager.contentsOfDirectory(atPath: canonical.path)
        if !existing.isEmpty {
            guard replace else { throw TreeError.notEmpty(canonical.path) }
            for name in existing { try manager.removeItem(at: canonical.appendingPathComponent(name)) }
        }
        let planned = nodes.reduce(0) { total, node in
            if case .file(_, let size, _, _) = node { return total + size.bytes }
            return total
        }
        guard planned <= maxBytes else { throw TreeError.tooLarge(planned) }

        var created: [String: URL] = [:]
        var ages: [(URL, Date)] = []
        func url(_ path: String) throws -> URL {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                throw TreeError.invalidPath(path)
            }
            let target = parts.reduce(canonical) { $0.appendingPathComponent(String($1)) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            return target
        }
        for node in nodes {
            let target = try url(node.path)
            switch node {
            case .file(_, let size, let seed, let age):
                try Self.write(size: size.bytes, seed: seed ?? Self.seed(for: node.path), to: target)
                age.map { ages.append((target, $0.date(relativeTo: now))) }
            case .text(_, let contents, let age):
                try Data(contents.utf8).write(to: target)
                age.map { ages.append((target, $0.date(relativeTo: now))) }
            case .directory(_, let age):
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                age.map { ages.append((target, $0.date(relativeTo: now))) }
            case .hardLink(_, let source):
                guard let original = created[source] else { throw TreeError.missingSource(source) }
                guard link(original.path, target.path) == 0 else { throw TreeError.system(target.path, errno) }
            case .symlink(_, let destination):
                guard symlink(destination, target.path) == 0 else { throw TreeError.system(target.path, errno) }
            case .package(_, let bundleId, let age):
                let contents = target.appendingPathComponent("Contents")
                try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                let plist: [String: Any] = ["CFBundleIdentifier": bundleId ?? "dev.agentdevkit.fixture." + target.deletingPathExtension().lastPathComponent,
                                            "CFBundleName": target.deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                age.map { ages.append((target, $0.date(relativeTo: now))) }
            case .duplicate(_, let source, let age):
                guard let original = created[source] else { throw TreeError.missingSource(source) }
                try manager.copyItem(at: original, to: target)
                age.map { ages.append((target, $0.date(relativeTo: now))) }
            }
            created[node.path] = target
        }
        // Set dates last and deepest first, because adding a child changes its folder's date.
        for (target, date) in ages.sorted(by: { $0.0.pathComponents.count > $1.0.pathComponents.count }) {
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        }
        return try FileTreeManifest(root: canonical, nodes: nodes)
    }

    /// `realpath` of an existing directory.
    public static func canonical(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw TreeError.system(url.path, errno) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// FNV-1a of the path, so unseeded files are deterministic but differ from each other.
    static func seed(for path: String) -> UInt64 {
        path.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    /// SplitMix64 bytes, written in chunks.
    static func write(size: Int, seed: UInt64, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw TreeError.system(url.path, errno) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var state = seed
        var remaining = size
        var chunk = [UInt8](repeating: 0, count: min(size, 65_536))
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            var index = 0
            while index < count {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z ^= z >> 31
                for shift in stride(from: 0, to: 64, by: 8) where index < count {
                    chunk[index] = UInt8(truncatingIfNeeded: z >> UInt64(shift))
                    index += 1
                }
            }
            try handle.write(contentsOf: chunk[0..<count])
            remaining -= count
        }
    }
}

/// What a materialized tree contains, for expected values in recipes and tests.
public struct FileTreeManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case file, directory, hardLink, symlink, package }
        /// Relative to the root.
        public let path: String
        public let kind: Kind
        public let size: Int
        /// SHA-256 of file contents, for files and hard links.
        public let sha256: String?
        public let inode: UInt64
        public let modified: Date
        /// The link target, for hard links (relative path) and symbolic links (as stored).
        public let target: String?
    }

    /// The canonical root, after `realpath`.
    public let root: String
    public let entries: [Entry]
    public let totalBytes: Int

    init(root: URL, nodes: [FileTree.Node]) throws {
        self.root = root.path
        var entries: [Entry] = []
        var total = 0
        for node in nodes {
            let url = root.appendingPathComponent(node.path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw FileTree.TreeError.system(url.path, errno) }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            let kind: Entry.Kind
            var target: String?
            var digest: String?
            switch node {
            case .file, .text, .duplicate: kind = .file
            case .directory: kind = .directory
            case .package: kind = .package
            case .hardLink(_, let source):
                kind = .hardLink
                target = source
            case .symlink(_, let destination):
                kind = .symlink
                target = destination
            }
            if kind == .file || kind == .hardLink {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if kind == .file { total += data.count }
            }
            entries.append(Entry(path: node.path, kind: kind, size: Int(info.st_size), sha256: digest, inode: UInt64(info.st_ino),
                                 modified: modified, target: target))
        }
        self.entries = entries
        totalBytes = total
    }

    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    /// Paths of files whose contents equal another file's, grouped by digest, for duplicate-finder expectations.
    public var duplicateGroups: [[String]] {
        let files = entries.filter { $0.kind == .file }
        return Dictionary(grouping: files, by: { $0.sha256 ?? "" }).values
            .filter { $0.count > 1 }.map { $0.map(\.path).sorted() }.sorted { $0[0] < $1[0] }
    }
}
