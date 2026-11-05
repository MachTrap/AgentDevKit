import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import AppKit
import Foundation
import Testing

/// A real AppKit window with identified controls, inspected through the bridge.
@MainActor
final class WindowApp: AgentAdapter {
    let runtime: AgentRuntime
    let window: NSWindow
    private(set) var presses = 0
    let secret = "tok-secret-42"

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Inspection \(UUID().uuidString.prefix(6))"
        window.identifier = NSUserInterfaceItemIdentifier("inspection-window")
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        let button = NSButton(title: "Go", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 160, width: 100, height: 32)
        button.setAccessibilityIdentifier("button.go")
        button.target = self
        button.action = #selector(go)
        let field = NSTextField(string: "Bearer \(secret)")
        field.frame = NSRect(x: 20, y: 110, width: 300, height: 24)
        field.setAccessibilityIdentifier("field.token")
        let password = NSSecureTextField(string: "hunter2")
        password.frame = NSRect(x: 20, y: 70, width: 300, height: 24)
        password.setAccessibilityIdentifier("field.password")
        let disabled = NSButton(title: "Off", target: nil, action: nil)
        disabled.frame = NSRect(x: 140, y: 160, width: 100, height: 32)
        disabled.isEnabled = false
        disabled.setAccessibilityIdentifier("button.off")
        [button, field, password, disabled].forEach(content.addSubview)
        window.contentView = content
        window.orderFrontRegardless()
    }

    @objc func go() {
        presses += 1
        runtime.record("button.pressed", scope: "app")
    }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        ScreenSnapshot(screenId: "inspection", windowId: "inspection-window", ready: true, fields: ["presses": .integer(Int64(presses))])
    }

    func secretValues() -> [String] { [secret] }
    func window(for windowId: String?) -> NSWindow? { window }
}

@Suite(.serialized) @MainActor struct UIInspectionTests {
    private func run(ui: UIAccess = .all, allowMutations: Bool = true, _ body: (WindowApp, AgentClient) async throws -> Void) async throws {
        let runtime = AgentRuntime()
        let app = WindowApp(runtime: runtime)
        defer { app.window.close() }
        let bundleId = "dev.agentdevkit.tests.ui." + UUID().uuidString
        let host = AgentHost(adapter: app, runtime: runtime, catalog: AgentCatalog(scopes: ["app"], ui: ui), allowMutations: allowMutations,
                             configuration: .init(identity: .fixed(bundleId: bundleId, buildFingerprint: "ui")))
        try await host.start()
        do { try await body(app, try AgentClient(session: bundleId)) } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test func captureRendersTheWindowWithinTheResponseLimit() async throws {
        try await run { app, client in
            let capabilities = try #require(try await client.capabilities().result)
            #expect(capabilities.ui == ["capture", "tree", "press", "perform", "input"])
            let capture = try #require(try await client.call(UICommands.capture, CaptureRequest(maxDimension: 300)).result)
            #expect(max(capture.width, capture.height) <= 300)
            #expect(capture.title == app.window.title)
            let data = try #require(Data(base64Encoded: capture.data))
            #expect(data.count == capture.bytes)
            #expect(NSBitmapImageRep(data: data)?.pixelsWide == capture.width)
        }
    }

    @Test func treeListsIdentifiedControlsAndRedactsSecrets() async throws {
        try await run { _, client in
            let tree = try #require(try await client.call(UICommands.tree, TreeRequest(onlyIdentified: true)).result)
            let byId = Dictionary(tree.elements.compactMap { element in element.identifier.map { ($0, element) } }, uniquingKeysWith: { a, _ in a })
            #expect(Set(byId.keys).isSuperset(of: ["button.go", "field.token", "field.password", "button.off"]))
            #expect(byId["button.go"]?.role == "AXButton")
            #expect(byId["button.off"]?.enabled == false)
            #expect(byId["field.token"]?.value == "Bearer <redacted>")
            #expect(byId["field.password"]?.value == nil, "Secure fields never report a value.")
            let frame = try #require(byId["button.go"]?.frame)
            // The system tree reports the visible bezel, which is inset from the 100 × 32 view frame.
            #expect((60...110).contains(frame[2]) && (16...40).contains(frame[3]))
            let filtered = try #require(try await client.call(UICommands.tree, TreeRequest(identifierPrefix: "button.")).result)
            #expect(filtered.elements.compactMap(\.identifier).sorted() == ["button.go", "button.off"])
        }
    }

    @Test func pressRunsTheControlActionAndRespectsState() async throws {
        try await run { app, client in
            let before = try #require(try await client.call(AppCommands.snapshot, SnapshotRequest(scope: "app")).result).revision
            let pressed = try #require(try await client.call(UICommands.press, PressRequest(identifier: "button.go")).result)
            #expect(app.presses == 1)
            #expect(pressed.revision > before)
            await #expect(throws: Failure.self) { try await client.call(UICommands.press, PressRequest(identifier: "button.off")) }
            await #expect(throws: Failure.self) { try await client.call(UICommands.press, PressRequest(identifier: "missing")) }
            #expect(app.presses == 1)
        }
    }

    @Test func readOnlySessionsDoNotPressAndDisabledToolsAreAbsent() async throws {
        try await run(allowMutations: false) { app, client in
            let capabilities = try #require(try await client.capabilities().result)
            #expect(capabilities.ui == ["capture", "tree"])
            #expect(!capabilities.methods.contains("ui.press"))
            let denied = await failure { try await client.call(UICommands.press, PressRequest(identifier: "button.go")) }
            #expect(denied?.code == .permissionDenied)
            #expect(app.presses == 0)
        }
        try await run(ui: []) { _, client in
            let capabilities = try #require(try await client.capabilities().result)
            #expect(capabilities.ui == nil)
            let missing = await failure { try await client.call(UICommands.capture, CaptureRequest()) }
            #expect(missing?.code == .unknownMethod)
        }
    }

    private func failure(_ body: () async throws -> some Any) async -> Failure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? Failure
        }
    }
}
