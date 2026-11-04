import AgentDevKitHost
import AppKit
import Observation

@MainActor
@Observable
final class TestingSession: NSObject, NSApplicationDelegate {
    let model = LabModel()
    private var host: AgentHost?
    private var lifecycle: Task<Void, Never>?
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
        lifecycle = Task {
            do {
                try await host.start()
                status = allowMutations ? "AgentTesting · Bridge active · Test mutations enabled" : "AgentTesting · Bridge active · Read-only"
            } catch {
                status = "AgentTesting · Bridge failed to start"
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle, let host else { return .terminateNow }
        Task {
            await lifecycle.value
            await host.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
