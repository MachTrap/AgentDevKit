import AgentDevKitHost
import AppKit
import Observation
#if ADK_LOOPBACK
import Darwin
import DevelopmentIdentity
#endif

@MainActor
@Observable
final class TestingSession: NSObject, NSApplicationDelegate {
    let model = LabModel()
    private var host: AgentHost?
    private var lifecycle: Task<Void, Never>?
    #if ADK_LOOPBACK
    private let pairingDefaults = UserDefaults.standard
    private let bookmarkKey = "AgentDevKitPairingBookmark"
    private var panel: NSOpenPanel?
    private var pairingFolder: URL?
    private var hasSecurityScope = false
    private var stopping = false
    private var mutationAccess = false
    private(set) var pairingEnabled = false
    private(set) var paired = false
    #endif
    private(set) var status = "AgentTesting · Bridge disabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let runtime = LabRuntime(model: model)
        var storageAvailable = false
        do {
            let storage = try TestingWorkspace(arguments: arguments)
            try model.configure(load: storage.load, save: storage.save)
            storageAvailable = true
        } catch {
            model.reportStorageError()
        }
        let allowMutations = storageAvailable && arguments.contains("--allow-agentdevkit-mutations")
        let commands = LabCommands(model: model, runtime: runtime, allowMutations: allowMutations)
        if storageAvailable, !arguments.contains("--agentdevkit-profile"),
           let index = arguments.firstIndex(of: "--agentdevkit-fixture") {
            do {
                guard index + 1 < arguments.count,
                      let fixture = Fixture.all.first(where: { $0.id == arguments[index + 1] }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                _ = try commands.apply(fixture)
            } catch {
                model.reportStorageError()
            }
        }
        guard arguments.contains("--enable-agentdevkit") else { return }
        let lifecycleCapabilities = LabCommands.lifecycleCapabilities(allowMutations: allowMutations)
        let host = AgentHost(
            commands: commands.definitions, allowMutations: allowMutations,
            routes: LabCommands.routes, fixtures: Fixture.all.map(\.id), scopes: LabCommands.scopes, actions: commands.actions.map(\.id),
            lifecycle: lifecycleCapabilities
        )
        self.host = host
        #if ADK_LOOPBACK
        pairingEnabled = true
        mutationAccess = allowMutations
        let bookmark = pairingDefaults.data(forKey: bookmarkKey)
        startLoopback(selectFolder: bookmark == nil, allowMutations: allowMutations)
        #else
        lifecycle = Task {
            do {
                #if ADK_APP_GROUP
                guard let id = Bundle.main.object(forInfoDictionaryKey: "AgentDevKitAppGroup") as? String else {
                    throw CocoaError(.featureUnsupported)
                }
                try await host.start(transport: .appGroup(id))
                #else
                try await host.start()
                #endif
                showActive(allowMutations)
            } catch {
                status = "AgentTesting · Bridge failed: \(error)"
            }
        }
        #endif
    }

    private func showActive(_ allowMutations: Bool) {
        status = allowMutations ? "AgentTesting · Bridge active · Test mutations enabled" : "AgentTesting · Bridge active · Read-only"
    }

    #if ADK_LOOPBACK
    func choosePairingFolder() {
        guard pairingEnabled, !paired, !stopping, lifecycle == nil else { return }
        startLoopback(selectFolder: true, allowMutations: mutationAccess)
    }

    func forgetPairingFolder() {
        guard paired, !stopping, let host else { return }
        stopping = true
        paired = false
        pairingDefaults.removeObject(forKey: bookmarkKey)
        lifecycle = Task {
            await host.stop()
            releasePairingFolder()
            status = "AgentTesting · Pairing forgotten"
            stopping = false
            lifecycle = nil
        }
    }

    private func startLoopback(selectFolder: Bool, allowMutations: Bool) {
        guard let host else { return }
        lifecycle = Task {
            defer { lifecycle = nil }
            var folderValidated = false
            do {
                let folder: URL
                if selectFolder {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = true
                    picker.canChooseFiles = false
                    picker.canCreateDirectories = true
                    picker.prompt = "Pair"
                    picker.message = "Select a private folder with permissions 0700 for AgentDevKit tools."
                    panel = picker
                    let result = await picker.begin()
                    panel = nil
                    guard result == .OK, let url = picker.url else {
                        status = "AgentTesting · Pairing required"
                        return
                    }
                    folder = url
                } else {
                    var stale = false
                    guard let bookmark = pairingDefaults.data(forKey: bookmarkKey) else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale else { throw CocoaError(.fileReadNoPermission) }
                }
                try Task.checkCancellation()
                hasSecurityScope = folder.startAccessingSecurityScopedResource()
                guard hasSecurityScope || selectFolder else { throw CocoaError(.fileReadNoPermission) }
                pairingFolder = folder
                try validatePairingFolder(folder)
                let bookmark = selectFolder ? try folder.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
                ) : nil
                folderValidated = true
                if let bookmark { pairingDefaults.set(bookmark, forKey: bookmarkKey) }
                try await host.start(transport: .pairedLoopback(directory: folder, makeIdentity: DevelopmentIdentity.make))
                paired = true
                showActive(allowMutations)
            } catch is CancellationError {
                releasePairingFolder()
            } catch {
                releasePairingFolder()
                if !folderValidated { pairingDefaults.removeObject(forKey: bookmarkKey) }
                status = "AgentTesting · Pairing failed: \(error)"
            }
        }
    }

    private func validatePairingFolder(_ folder: URL) throws {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o7777) == (S_IFDIR | 0o700),
              Darwin.access(folder.path, W_OK | X_OK) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func releasePairingFolder() {
        if hasSecurityScope { pairingFolder?.stopAccessingSecurityScopedResource() }
        hasSecurityScope = false
        pairingFolder = nil
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host else { return .terminateNow }
        let pending = lifecycle
        #if ADK_LOOPBACK
        if !stopping { pending?.cancel() }
        panel?.cancel(nil)
        #endif
        Task {
            await pending?.value
            await host.stop()
            #if ADK_LOOPBACK
            releasePairingFolder()
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
