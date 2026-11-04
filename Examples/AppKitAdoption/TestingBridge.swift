import AgentDevKitCore
import AgentDevKitHost
import AppKit

@MainActor
final class TestingBridge {
    private var host: AgentHost?
    private var startup: Task<Void, Never>?

    func start(controller: DocumentWindowController) {
        guard CommandLine.arguments.contains("--enable-agentdevkit"), host == nil else { return }
        let scope = "selected-document"
        let host = AgentHost(commands: [
            AppCommand(AppCommands.snapshot, parameterKeys: ["scope"]) { [weak controller] request, _ in
                guard request.scope == scope else { throw Failure(.invalidParams, "Unknown scope.") }
                guard let controller, controller.isWindowLoaded, let window = controller.window else {
                    throw Failure(.notReady, "The document window is unavailable.")
                }
                return ScreenState(
                    screenId: "documents", windowId: "documents", ready: window.isVisible,
                    revision: controller.revision, scope: scope,
                    fields: ["selectedDocumentId": .string(controller.selectedDocumentID)]
                )
            }
        ], scopes: [scope])
        self.host = host
        startup = Task {
            do { try await host.start() }
            catch { NSLog("The read-only document bridge could not start.") }
        }
    }

    func terminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let host else { return .terminateNow }
        Task {
            await startup?.value
            await host.stop()
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
