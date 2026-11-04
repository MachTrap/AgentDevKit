import AgentDevKitCore
import AgentDevKitHost
import AppKit

/// A read-only bridge over the existing window controller. Testing target only.
@MainActor
final class TestingBridge: AgentAdapter {
    private let session = AgentSession()
    private let runtime = AgentRuntime()
    private weak var controller: DocumentWindowController?

    func start(controller: DocumentWindowController) {
        guard (try? LaunchOptions.parse())?.enabled == true else { return }
        self.controller = controller
        controller.onSelectionChange = { [runtime] in
            runtime.record("selection.changed", scope: "selected-document", changedFields: ["selectedDocumentId"])
        }
        let host = AgentHost(adapter: self, runtime: runtime, catalog: AgentCatalog(scopes: ["selected-document"]))
        session.start(host, readOnly: true)
    }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        guard let controller, controller.isWindowLoaded, let window = controller.window else {
            throw Failure(.notReady, "The document window is unavailable.")
        }
        return ScreenSnapshot(screenId: "documents", windowId: "documents", ready: window.isVisible,
                              fields: ["selectedDocumentId": .string(controller.selectedDocumentID)])
    }

    func terminate(_ app: NSApplication) -> NSApplication.TerminateReply { session.terminate(app) }
}
