import AgentDevKitTransport
import AppKit
import Foundation

/// Keeps the user-selected pairing folder of a sandboxed paired-loopback Testing build.
/// Only a security-scoped bookmark is stored, in the Testing app's own preferences.
@MainActor
public final class LoopbackPairing {
    public enum PairingError: Error, Sendable, Equatable, CustomStringConvertible {
        case folderUnavailable
        case folderInvalid

        public var description: String {
            switch self {
            case .folderUnavailable: "The paired folder is no longer accessible. Pair a folder again."
            case .folderInvalid: "Select a folder owned by you with permissions 0700."
            }
        }
    }

    private let defaults: UserDefaults
    private let bookmarkKey: String
    private var panel: NSOpenPanel?
    private var scopedFolder: URL?

    public init(bookmarkKey: String = "AgentDevKitPairingBookmark", defaults: UserDefaults = .standard) {
        self.bookmarkKey = bookmarkKey
        self.defaults = defaults
    }

    public var hasBookmark: Bool { defaults.data(forKey: bookmarkKey) != nil }

    /// Resolves the saved folder, or asks for one when `prompt` is true or none is saved.
    /// Returns nil when the user cancels the panel. The folder's security scope stays open until `release()`.
    func acquire(prompt: Bool) async throws(PairingError) -> URL? {
        let prompting = prompt || !hasBookmark
        let folder: URL
        if prompting {
            let picker = NSOpenPanel()
            picker.canChooseDirectories = true
            picker.canChooseFiles = false
            picker.canCreateDirectories = true
            picker.prompt = "Pair"
            picker.message = "Select a private folder with permissions 0700 for AgentDevKit tools."
            panel = picker
            let result = await picker.begin()
            panel = nil
            guard result == .OK, let url = picker.url else { return nil }
            folder = url
        } else {
            var stale = false
            guard let bookmark = defaults.data(forKey: bookmarkKey),
                  let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale
            else {
                forget()
                throw .folderUnavailable
            }
            folder = url
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        if scoped { scopedFolder = folder }
        guard scoped || prompting else {
            forget()
            throw .folderUnavailable
        }
        guard SessionDirectory.validatePairingFolder(folder) else {
            release()
            if prompting { forget() }
            throw .folderInvalid
        }
        if prompting {
            guard let bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
                release()
                throw .folderUnavailable
            }
            defaults.set(bookmark, forKey: bookmarkKey)
        }
        return folder
    }

    /// Ends access to the folder. Call after the bridge stopped.
    func release() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    /// Removes the saved bookmark.
    func forget() { defaults.removeObject(forKey: bookmarkKey) }

    func cancelPrompt() { panel?.cancel(nil) }
}
