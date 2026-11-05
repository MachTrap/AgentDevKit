import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import AgentDevKitTransport
import AppKit
import Darwin
import Foundation
import Testing

/// Finishes launching the test process's `NSApplication`, so it serves the system accessibility tree as a real
/// app does (until then every AX query answers kAXErrorNotImplemented). The delegate refuses to terminate,
/// because AppKit would otherwise quit the test runner.
@MainActor
final class TestApplication: NSObject, NSApplicationDelegate {
    private static let shared = TestApplication()
    private static var launched = false

    static func launch() {
        _ = NSApplication.shared
        guard !launched else { return }
        launched = true
        NSApp.delegate = shared
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        NSApp.finishLaunching()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {}
}

/// Records key, hover and scroll input delivered to it.
@MainActor
final class InputView: NSView {
    var keys: [UInt16] = []
    var entered = 0
    var exited = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    override func mouseEntered(with event: NSEvent) { entered += 1 }
    override func mouseExited(with event: NSEvent) { exited += 1 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }
}

/// A queue-and-map app in one AppKit window, with every v0.6 feature registered.
@MainActor
final class QueueApp: AgentAdapter {
    let runtime: AgentRuntime
    let window: NSWindow
    let slider = NSSlider(value: 2, minValue: 0, maxValue: 4, target: nil, action: nil)
    let checkbox = NSButton(checkboxWithTitle: "Downloads", target: nil, action: nil)
    let popup = NSPopUpButton(frame: NSRect(x: 20, y: 120, width: 160, height: 26), pullsDown: false)
    let disclosure = NSButton(title: "", target: nil, action: nil)
    let input = InputView(frame: NSRect(x: 260, y: 20, width: 120, height: 60))
    let scroll = NSScrollView(frame: NSRect(x: 260, y: 100, width: 120, height: 100))
    var queued: [String] = []
    var map = ["Downloads", "Desktop"]
    var mapBug = false
    var detail = 2
    var density = "Regular"
    var expanded = false
    var fixtureLoads = 0

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        _ = NSApplication.shared
        // The system accessibility tree serves only processes that may own windows.
        TestApplication.launch()
        window = NSWindow(contentRect: NSRect(x: 640, y: 260, width: 420, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Queue \(UUID().uuidString.prefix(6))"
        window.identifier = NSUserInterfaceItemIdentifier("queue-window-\(UUID().uuidString.prefix(6))")
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        slider.frame = NSRect(x: 20, y: 200, width: 180, height: 24)
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityIdentifier("detail")
        slider.target = self
        slider.action = #selector(slid)
        checkbox.frame = NSRect(x: 20, y: 160, width: 120, height: 20)
        checkbox.setAccessibilityIdentifier("row")
        checkbox.target = self
        checkbox.action = #selector(checked)
        let size = NSTextField(labelWithString: "4.2 GB")
        size.frame = NSRect(x: 150, y: 160, width: 80, height: 20)
        // The SwiftUI copy-down shape: one identifier on a checkbox and a label of the same row.
        size.setAccessibilityIdentifier("row")
        popup.addItems(withTitles: ["Compact", "Regular", "Spacious"])
        popup.selectItem(withTitle: "Regular")
        popup.setAccessibilityIdentifier("density")
        popup.target = self
        popup.action = #selector(chose)
        disclosure.frame = NSRect(x: 20, y: 80, width: 20, height: 20)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = .off
        disclosure.setAccessibilityIdentifier("advanced")
        disclosure.target = self
        disclosure.action = #selector(disclosed)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 1_000))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        document.scroll(NSPoint(x: 0, y: 900))
        [slider, checkbox, size, popup, disclosure, input, scroll].forEach(content.addSubview)
        window.contentView = content
        window.orderFrontRegardless()
        window.makeFirstResponder(input)
    }

    @objc func slid() { detail = Int(slider.doubleValue.rounded()); runtime.record("detail.changed", scope: "app", changedFields: ["detail"]) }
    @objc func checked() { toggle("Downloads") }
    @objc func chose() { density = popup.titleOfSelectedItem ?? ""; runtime.record("density.changed", scope: "app", changedFields: ["density"]) }
    @objc func disclosed() { expanded = disclosure.state == .on; runtime.record("advanced.changed", scope: "app", changedFields: ["expanded"]) }

    func toggle(_ name: String) {
        if let index = queued.firstIndex(of: name) {
            queued.remove(at: index)
            if !map.contains(name) { map.append(name) }
        } else {
            queued.append(name)
            if !mapBug { map.removeAll { $0 == name } }
        }
        runtime.record("queue.changed", scope: "app", changedFields: ["queued", "map"])
    }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        ScreenSnapshot(screenId: "queue", windowId: "queue", ready: true, fields: [
            "queued": .array(queued.map(JSONValue.string)), "queueCount": .integer(Int64(queued.count)),
            "map": .array(map.map(JSONValue.string)), "stale": .array(queued.filter(map.contains).map(JSONValue.string)),
            "detail": .integer(Int64(detail)), "density": .string(density), "expanded": .bool(expanded), "phase": "results",
        ])
    }

    func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue] {
        if id == "slow-v1" { try await Task.sleep(for: .milliseconds(1_500)) }
        queued = []
        map = ["Downloads", "Desktop"]
        fixtureLoads += 1
        runtime.record("fixture.loaded", scope: "app", correlationId: context.requestId, changedFields: ["queued"])
        return ["loads": .integer(Int64(fixtureLoads))]
    }

    func window(for windowId: String?) -> NSWindow? {
        guard let windowId, windowId != "main" else { return window }
        return NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue == windowId || "window-\($0.windowNumber)" == windowId) }
    }

    struct Names: Decodable { let names: [String] }
    struct Flag: Decodable { let enabled: Bool }
    struct None: Decodable {}

    var catalog: AgentCatalog {
        AgentCatalog(
            scopes: ["current-screen", "app"],
            fixtures: ["quick-v1", "slow-v1"],
            actions: [
                AgentAction("queue.toggle", scope: "app", input: ObjectSchema(["names": .array(.string(maxLength: 32))], required: ["names"]),
                            as: Names.self) { [unowned self] input, _ in
                    input.names.forEach(toggle)
                    return .completed
                },
                AgentAction("map.bug", scope: "app", input: ObjectSchema(["enabled": .boolean], required: ["enabled"]), as: Flag.self) { [unowned self] input, _ in
                    mapBug = input.enabled
                    if !input.enabled {
                        map = ["Downloads", "Desktop"].filter { !queued.contains($0) }
                        runtime.record("map.rebuilt", scope: "app", changedFields: ["map"])
                    }
                    return .completed
                },
                AgentAction("confirm", scope: "app", input: .empty, as: None.self, presentsUI: true) { [unowned self] _, _ in
                    let alert = NSAlert()
                    alert.messageText = "Empty the queue?"
                    alert.addButton(withTitle: "Empty")
                    alert.addButton(withTitle: "Keep")
                    alert.buttons[0].setAccessibilityIdentifier("alert.empty")
                    let response = await withCheckedContinuation { continuation in
                        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                    }
                    guard response == .alertFirstButtonReturn else { throw Failure(.cancelled, "Kept the queue.") }
                    queued = []
                    runtime.record("queue.emptied", scope: "app", changedFields: ["queued"])
                    return .completed
                },
            ],
            diagnosticCategories: ["queue"],
            ui: .all,
            invariants: [
                AgentInvariant("queue.mapConsistent", scope: "app") { screen in
                    let stale = screen.fields["stale"]?.arrayValue ?? []
                    return stale.isEmpty ? .holds : .violated(details: ["stale": .array(stale)])
                }
            ],
            experiments: [
                AgentExperiment("probe.count", input: ObjectSchema(["of": .string(maxLength: 16)], required: ["of"])) { [unowned self] arguments, _ in
                    ["count": .integer(Int64(arguments["of"] == "queue" ? queued.count : map.count))]
                },
                AgentExperiment("probe.reset", readOnly: false) { [unowned self] _, _ in
                    queued = []
                    return ["reset": true]
                },
            ],
            operatorPrompts: true
        )
    }
}

struct QueueHost {
    let host: AgentHost
    let app: QueueApp
    let client: AgentClient
    let bundleId: String

    @MainActor
    static func run(allowMutations: Bool = true, _ body: (QueueHost) async throws -> Void) async throws {
        let runtime = AgentRuntime()
        let app = QueueApp(runtime: runtime)
        defer { app.window.close() }
        let bundleId = "dev.agentdevkit.tests.queue." + UUID().uuidString
        let host = AgentHost(adapter: app, runtime: runtime, catalog: app.catalog, allowMutations: allowMutations,
                             configuration: .init(identity: .fixed(bundleId: bundleId, buildFingerprint: "queue")))
        try await host.start()
        let queue = QueueHost(host: host, app: app, client: try AgentClient(session: bundleId), bundleId: bundleId)
        do { try await body(queue) } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    func call<Input, Output>(_ command: Command<Input, Output>, _ input: Input, timeoutMs: Int? = nil) async throws -> Output {
        try #require(try await client.call(command, input, timeoutMs: timeoutMs).result)
    }

    @MainActor func failure(_ body: @MainActor () async throws -> some Any) async -> Failure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? Failure
        }
    }

    func operation(_ tool: String) throws -> AgentOperation { try #require(AgentOperation.all.first { $0.tool == tool }) }
}

@Suite(.serialized) @MainActor struct FeatureTests {
    // MARK: 1 · Discoverable errors

    @Test func unknownNamesSuggestAndConditionAliasesResolve() async throws {
        try await QueueHost.run { queue in
            let alias = try await queue.call(AppCommands.wait, WaitRequest(condition: "state.fieldEquals", scope: "app",
                                                                           arguments: ["field": "phase", "value": "results"]))
            #expect(alias.satisfied && alias.condition == "state.field_equals")
            let typo = await queue.failure {
                try await queue.call(AppCommands.wait, WaitRequest(condition: "state.feild_equals", scope: "app",
                                                                   arguments: ["field": "phase", "value": "results"]))
            }
            #expect(typo?.code == .invalidParams)
            #expect(typo?.details?["closest"] == "state.field_equals")
            #expect(typo?.details?["validNames"]?.arrayValue?.contains("invariants.hold") == true)
            let example = try #require(typo?.details?["example"]?.stringValue)
            #expect(example == "agentdevctl wait --condition state.field_equals --scope app --field phase --value results")
            // The example runs: parse it as the CLI would and send it.
            let wait = try queue.operation("wait")
            let reply = try await wait.run(queue.client, ["condition": "state.field_equals", "scope": "app",
                                                          "arguments.field": "phase", "arguments.value": "results"])
            #expect(reply.objectValue?["result"]?.objectValue?["satisfied"] == true)

            let fixture = await queue.failure { try await queue.call(AppCommands.load, LoadFixture(fixture: "quick-v2")) }
            #expect(fixture?.code == .fixtureNotFound && fixture?.details?["closest"] == "quick-v1")
            let action = await queue.failure { try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.togle", arguments: [:])) }
            #expect(action?.code == .actionNotFound && action?.details?["closest"] == "queue.toggle")
            #expect(action?.details?["example"]?.stringValue?.contains(#"--args '{"names":[]}'"#) == true)
            let scope = await queue.failure { try await queue.call(AppCommands.snapshot, SnapshotRequest(scope: "ap")) }
            #expect(scope?.code == .invalidParams && scope?.details?["closest"] == "app")
            let experiment = await queue.failure { try await queue.call(ExperimentCommands.run, ExperimentRequest(experimentId: "probe.cont")) }
            #expect(experiment?.details?["closest"] == "probe.count")
        }
    }

    // MARK: 3 · Tracked operations

    @Test func slowFixturesAreAcceptedAndReportTheirResult() async throws {
        try await QueueHost.run { queue in
            let started = ContinuousClock.now
            let accepted = try await queue.client.call(AppCommands.load, LoadFixture(fixture: "slow-v1"), timeoutMs: 800)
            #expect(started.duration(to: .now) < .milliseconds(1_200), "The reply arrives within the request deadline.")
            #expect(accepted.status == .accepted)
            let operation = try #require(accepted.result?.operationId)
            #expect(try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: operation)).state == .pending)
            let busy = await queue.failure { try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.toggle", arguments: ["names": ["Desktop"]])) }
            #expect(busy?.code == .conflict && busy?.retryable == true && busy?.details?["operationId"] == .string(operation.uuidString))
            _ = try await queue.call(AppCommands.wait, WaitRequest(condition: "operation.completed", scope: "app",
                                                                   arguments: ["operationId": .string(operation.uuidString)]))
            let status = try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: operation))
            #expect(status.state == .completed && status.method == "fixtures.load")
            #expect(status.result?.objectValue?["fields"]?.objectValue?["loads"] == 1)
            #expect(status.revision != nil)

            // --wait follows an accepted reply to its final result.
            let fixtures = try queue.operation("fixtures")
            let followed = try await fixtures.run(queue.client, ["fixture": "slow-v1", "wait": true], timeoutMs: 800)
            #expect(followed.objectValue?["status"] == "completed")
            #expect(followed.objectValue?["result"]?.objectValue?["fields"]?.objectValue?["loads"] == 2)
        }
    }

    @Test func statusSurvivesAClientThatGaveUp() async throws {
        try await QueueHost.run { queue in
            let descriptor = try #require(try SessionDirectory.discover(.local).first { $0.identity.bundleId == queue.bundleId })
            let requestId = UUID()
            let envelope: [String: Any] = [
                "protocol": Wire.version, "requestId": requestId.uuidString, "sessionId": descriptor.identity.sessionId.uuidString,
                "auth": descriptor.auth, "method": AppCommands.load.method, "params": ["fixture": "slow-v1"], "timeoutMs": 2_000,
            ]
            let path = try SessionDirectory(id: descriptor.identity.sessionId).socketPath
            // The client stops listening after 150 ms, as a killed or disconnected client would.
            await #expect(throws: (any Error).self) {
                _ = try await LocalSocket.exchange(try JSONSerialization.data(withJSONObject: envelope), path: path, expectedPID: getpid(), timeoutMs: 150)
            }
            let pending = try await queue.call(OperationCommands.status, OperationStatusRequest(requestId: requestId))
            #expect(pending.state == .pending && pending.method == "fixtures.load")
            // Still running: the reconcile answers as if the host had replied accepted, never "safe to retry".
            let reconciled = try await AgentOperation.reconcile(Failure(.connectionLost, "lost"), client: queue.client, requestId: requestId)
            #expect(reconciled.objectValue?["status"] == "accepted")
            #expect(reconciled.objectValue?["result"]?.objectValue?["operationId"] == .string(requestId.uuidString))
            try await Task.sleep(for: .milliseconds(1_600))
            let done = try await queue.call(OperationCommands.status, OperationStatusRequest(requestId: requestId))
            #expect(done.state == .completed && done.summary.hasPrefix("applied at revision"))

            let unknown = UUID()
            #expect(try await queue.call(OperationCommands.status, OperationStatusRequest(requestId: unknown)).state == .unknown)
            do {
                _ = try await AgentOperation.reconcile(Failure(.connectionLost, "lost"), client: queue.client, requestId: unknown)
                Issue.record("An unknown request must not be reported as applied.")
            } catch let failure as Failure {
                #expect(failure.details?["remedy"] == "Not applied, safe to retry.")
            }
            let invalid = await queue.failure { try await queue.call(OperationCommands.status, OperationStatusRequest()) }
            #expect(invalid?.code == .invalidParams)
        }
    }

    @Test func actionsThatPresentUIAreTrackedAndAwaitTheUser() async throws {
        try await QueueHost.run { queue in
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.toggle", arguments: ["names": ["Desktop"]]))
            let actions = try await queue.call(AppCommands.actions, EmptyParameters())
            #expect(actions.first { $0.id == "confirm" }?.presentsUI == true)
            let reply = try await queue.client.call(AppCommands.invoke, ActionRequest(actionId: "confirm", arguments: [:]))
            #expect(reply.status == .accepted && reply.result?.outcome == .accepted)
            let operation = try #require(reply.result?.operationId)
            try await Task.sleep(for: .milliseconds(400))
            let listed = try await queue.call(OperationCommands.list, EmptyParameters()).first { $0.id == operation }
            #expect(listed?.awaitingUser == true)
            #expect(try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: operation)).awaitingUser == true)
            let surfaces = try await queue.call(UICommands.surfaces, SurfacesRequest()).surfaces
            let sheet = try #require(surfaces.first { $0.parentId != nil && ($0.kind == .alert || $0.kind == .sheet) })
            // A scripted answer: press the alert's first button through accessibility.
            _ = try await queue.call(UICommands.press, PressRequest(identifier: "alert.empty", windowId: sheet.id))
            _ = try await queue.call(AppCommands.wait, WaitRequest(condition: "operation.completed", scope: "app",
                                                                   arguments: ["operationId": .string(operation.uuidString)]))
            let status = try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: operation))
            #expect(status.state == .completed)
            #expect(queue.app.queued.isEmpty)

            // The cancel path: dismiss closes the sheet without its buttons.
            let second = try #require(try await queue.client.call(AppCommands.invoke, ActionRequest(actionId: "confirm", arguments: [:])).result?.operationId)
            try await Task.sleep(for: .milliseconds(400))
            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "dismiss", locator: ElementLocator()))
            _ = try await queue.call(AppCommands.wait, WaitRequest(condition: "lifecycle.ended", scope: "app",
                                                                   arguments: ["operationId": .string(second.uuidString)]))
            let cancelled = try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: second))
            #expect(cancelled.state == .cancelled && cancelled.reason == "Kept the queue.")
        }
    }

    // MARK: 4 · Surfaces and capture

    @Test func surfacesAndActiveCaptureIncludeSheetsAndRejectStaleRevisions() async throws {
        try await QueueHost.run { queue in
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            let label = NSTextField(labelWithString: "Sheet")
            label.frame = NSRect(x: 20, y: 40, width: 100, height: 20)
            label.setAccessibilityIdentifier("sheet.label")
            sheet.contentView?.addSubview(label)
            queue.app.window.beginSheet(sheet) { _ in }
            defer { queue.app.window.endSheet(sheet) }
            try await Task.sleep(for: .milliseconds(500))
            let list = try await queue.call(UICommands.surfaces, SurfacesRequest())
            let base = try #require(list.surfaces.first { $0.id == queue.app.window.identifier?.rawValue })
            let attached = try #require(list.surfaces.first { $0.kind == .sheet })
            #expect(attached.parentId == base.id)
            #expect(base.frame.count == 4 && base.title == queue.app.window.title)

            let active = try await queue.call(UICommands.capture, CaptureRequest(maxDimension: 600))
            #expect(active.mode == "active" && active.surfaces == [base.id, attached.id], "The sheet is drawn above its window.")
            let single = try await queue.call(UICommands.capture, CaptureRequest(maxDimension: 600, mode: "window"))
            #expect(single.mode == "window" && single.surfaces == [base.id])
            let surface = try await queue.call(UICommands.capture, CaptureRequest(maxDimension: 300, surfaceId: attached.id))
            #expect(surface.mode == "surface" && surface.surfaces == [attached.id])

            let revision = try await queue.call(AppCommands.snapshot, SnapshotRequest(scope: "app")).revision
            _ = try await queue.call(UICommands.capture, CaptureRequest(maxDimension: 200, revision: revision))
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.toggle", arguments: ["names": ["Desktop"]]))
            let stale = await queue.failure { try await queue.call(UICommands.capture, CaptureRequest(maxDimension: 200, revision: revision)) }
            #expect(stale?.code == .staleRevision)
            let staleTree = await queue.failure { try await queue.call(UICommands.tree, TreeRequest(revision: revision)) }
            #expect(staleTree?.code == .staleRevision)

            let snapshot = try await queue.call(UICommands.snapshot, UISnapshotRequest(maxDimension: 400, onlyIdentified: true))
            #expect(snapshot.revision == snapshot.capture.revision && snapshot.revision == snapshot.tree.revision)
            #expect(snapshot.tree.elements.contains { $0.identifier == "detail" })
            #expect(snapshot.surfaces.contains { $0.kind == .sheet })
        }
    }

    // MARK: 5 · Targeting and typed operations

    @Test func treeReportsPathsValuesAndIdentifierLint() async throws {
        try await QueueHost.run { queue in
            let tree = try await queue.call(UICommands.tree, TreeRequest(lint: true))
            let slider = try #require(tree.elements.first { $0.identifier == "detail" })
            #expect(slider.numericValue == 2 && slider.minValue == 0 && slider.maxValue == 4)
            #expect(slider.actions?.contains("increment") == true)
            #expect(slider.path == "detail")
            var rowPaths: [String] = []
            for element in tree.elements where element.identifier == "row" { rowPaths.append(element.path ?? "") }
            #expect(rowPaths == ["row", "row[1]"])
            let lint = try #require(tree.lint)
            #expect(lint.contains { $0.kind == .copiedDown && $0.identifier == "row" && $0.fix.contains(".accessibilityElement(children: .contain)") })
            #expect(lint.contains { $0.kind == .duplicate && $0.identifier == "row" && $0.paths == ["row", "row[1]"] })

            let ambiguous = await queue.failure { try await queue.call(UICommands.press, PressRequest(identifier: "row")) }
            #expect(ambiguous?.code == .ambiguousElement)
            #expect(ambiguous?.details?["paths"] == ["row", "row[1]"])
            let pressed = try await queue.call(UICommands.press, PressRequest(path: "row"))
            #expect(pressed.path == "row" && pressed.evidence == "accessibility")
            #expect(queue.app.queued == ["Downloads"])
            _ = try await queue.call(UICommands.press, PressRequest(role: "checkbox", label: "Downloads"))
            #expect(queue.app.queued.isEmpty)
            _ = try await queue.call(UICommands.press, PressRequest(identifier: "row", index: 0))
            #expect(queue.app.queued == ["Downloads"])
            let missing = await queue.failure { try await queue.call(UICommands.press, PressRequest(identifier: "detial")) }
            #expect(missing?.code == .notReady && missing?.details?["closest"] == "detail")
        }
    }

    @Test func performDrivesRealControlsAndReadOnlySessionsRefuse() async throws {
        try await QueueHost.run { queue in
            let set = try await queue.call(UICommands.perform, PerformRequest(operation: "set", locator: ElementLocator(identifier: "detail"), value: 4))
            #expect(set.numericValue == 4 && set.evidence == "accessibility")
            #expect(try await queue.call(AppCommands.snapshot, SnapshotRequest(scope: "app")).fields["detail"] == 4)
            let stepped = try await queue.call(UICommands.perform, PerformRequest(operation: "decrement", locator: ElementLocator(identifier: "detail")))
            #expect(stepped.numericValue == 3)
            let outside = await queue.failure { try await queue.call(UICommands.perform, PerformRequest(operation: "set", locator: ElementLocator(identifier: "detail"), value: 9)) }
            #expect(outside?.code == .invalidParams)

            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "choose", locator: ElementLocator(identifier: "density"), item: "spacious"))
            #expect(queue.app.density == "Spacious")
            let unknownItem = await queue.failure { try await queue.call(UICommands.perform, PerformRequest(operation: "choose", locator: ElementLocator(identifier: "density"), item: "Huge")) }
            #expect(unknownItem?.details?["validNames"] == ["Compact", "Regular", "Spacious"])

            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "expand", locator: ElementLocator(identifier: "advanced")))
            #expect(queue.app.expanded)
            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "expand", locator: ElementLocator(identifier: "advanced")))
            #expect(queue.app.expanded, "Expanding an expanded control changes nothing.")
            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "collapse", locator: ElementLocator(identifier: "advanced")))
            #expect(!queue.app.expanded)

            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "set", locator: ElementLocator(role: "checkbox", label: "Downloads"), value: true))
            #expect(queue.app.queued == ["Downloads"])
            _ = try await queue.call(UICommands.perform, PerformRequest(operation: "set", locator: ElementLocator(role: "checkbox", label: "Downloads"), value: true))
            #expect(queue.app.queued == ["Downloads"], "Setting a checkbox to its current state changes nothing.")
        }
        try await QueueHost.run(allowMutations: false) { queue in
            let capabilities = try #require(try await queue.client.capabilities().result)
            #expect(capabilities.ui == ["capture", "tree"])
            for method in [UICommands.perform.method, UICommands.key.method, UICommands.hover.method, UICommands.scroll.method, OperatorCommands.ask.method] {
                #expect(!capabilities.methods.contains(method))
            }
            let denied = await queue.failure { try await queue.call(UICommands.perform, PerformRequest(operation: "set", locator: ElementLocator(identifier: "detail"), value: 1)) }
            #expect(denied?.code == .permissionDenied)
            let key = await queue.failure { try await queue.call(UICommands.key, KeyRequest(keys: "Down")) }
            #expect(key?.code == .permissionDenied)
            #expect(queue.app.detail == 2)
        }
    }

    // MARK: 7 · In-process input

    @Test func keysHoverAndScrollReachTheAppsHandlers() async throws {
        try await QueueHost.run { queue in
            let keys = try await queue.call(UICommands.key, KeyRequest(keys: "Down Down Return a"))
            #expect(keys.events == 8 && keys.evidence == "in-process")
            #expect(queue.app.input.keys == [125, 125, 36, 0])
            let unknown = await queue.failure { try await queue.call(UICommands.key, KeyRequest(keys: "Dwn")) }
            #expect(unknown?.details?["closest"] == "down")

            // Window points from the top-left of the window frame, which includes the title bar.
            let center = queue.app.input.convert(NSPoint(x: 60, y: 30), to: nil)
            let y = Double(queue.app.window.frame.height - center.y)
            let hover = try await queue.call(UICommands.hover, HoverRequest(x: Double(center.x), y: y))
            #expect(queue.app.input.entered == 1 && hover.point == [Double(center.x), y])
            let away = try await queue.call(UICommands.hover, HoverRequest(x: 20, y: 20))
            #expect(queue.app.input.exited == 1 && away.point == [20, 20])

            let before = queue.app.scroll.contentView.bounds.origin.y
            let scrollCenter = queue.app.scroll.convert(NSPoint(x: 60, y: 50), to: nil)
            _ = try await queue.call(UICommands.scroll, ScrollRequest(x: Double(scrollCenter.x), y: Double(queue.app.window.frame.height - scrollCenter.y), dy: 200))
            #expect(queue.app.scroll.contentView.bounds.origin.y != before)
        }
    }

    // MARK: 9 · Invariants

    @Test func invariantViolationsAreReportedOnceAndResolve() async throws {
        try await QueueHost.run { queue in
            let start = try await queue.call(AppCommands.snapshot, SnapshotRequest(scope: "app")).revision
            #expect(try await queue.call(InvariantCommands.list, EmptyParameters()).invariants.first?.holds == true)
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "map.bug", arguments: ["enabled": true]))
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.toggle", arguments: ["names": ["Desktop"]]))
            try await Task.sleep(for: .milliseconds(50))
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "queue.toggle", arguments: ["names": ["Downloads"]]))
            let report = try await queue.call(InvariantCommands.list, EmptyParameters())
            let state = try #require(report.invariants.first)
            #expect(!state.holds && state.details?["stale"] == ["Desktop", "Downloads"])
            #expect(report.violations.count == 1, "A violation that stays open is reported once.")
            let violation = try #require(report.violations.first)
            #expect(violation.revision > start && violation.resolvedAt == nil)
            let diagnostics = try await queue.call(AppCommands.diagnostics, DiagnosticsRequest(category: "invariant"))
            #expect(diagnostics.count == 1 && diagnostics.first?.code == "queue.mapConsistent")
            let observed = try await queue.call(AppCommands.observe, ObserveRequest(scope: "app", sinceRevision: start))
            #expect(observed.violations?.map(\.id) == ["queue.mapConsistent"])
            let blocked = try await queue.call(AppCommands.wait, WaitRequest(condition: "invariants.hold", scope: "app", failOnTimeout: false), timeoutMs: 400)
            #expect(!blocked.satisfied && blocked.blockers == ["invariant:queue.mapConsistent"])

            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "map.bug", arguments: ["enabled": false]))
            let held = try await queue.call(AppCommands.wait, WaitRequest(condition: "invariants.hold", scope: "app"))
            #expect(held.satisfied)
            let resolved = try await queue.call(InvariantCommands.list, EmptyParameters())
            #expect(resolved.invariants.first?.holds == true && resolved.violations.first?.resolvedAt != nil)
            #expect(resolved.invariants.first.map { $0.maxCostMicros >= 0 && !$0.overBudget } == true)
            let unknown = await queue.failure { try await queue.call(AppCommands.wait, WaitRequest(condition: "invariants.hold", scope: "app", arguments: ["ids": ["nope"]])) }
            #expect(unknown?.code == .invalidParams)
        }
    }

    // MARK: 10 · Operator prompts

    @Test func operatorQuestionsAreAnsweredInThePanelOrTimeOut() async throws {
        try await QueueHost.run { queue in
            let ticket = try await queue.call(OperatorCommands.ask, OperatorQuestion(question: "Did a dialog appear?", options: ["Yes", "No"], allowNotes: true))
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await queue.call(OperatorCommands.answer, OperatorAnswerRequest(operationId: ticket.operationId)).status == .pending)
            let panel = try #require(try await queue.call(UICommands.surfaces, SurfacesRequest()).surfaces.first { $0.id.hasPrefix("agentdevkit.operator") })
            #expect(panel.title == "Agent question (Testing build)")
            #expect(try await queue.call(OperationCommands.list, EmptyParameters()).first { $0.id == ticket.operationId }?.awaitingUser == true)
            _ = try await queue.call(UICommands.press, PressRequest(identifier: "operator.option.0", windowId: panel.id))
            _ = try await queue.call(AppCommands.wait, WaitRequest(condition: "operation.completed", scope: "app",
                                                                   arguments: ["operationId": .string(ticket.operationId.uuidString)]))
            let answer = try await queue.call(OperatorCommands.answer, OperatorAnswerRequest(operationId: ticket.operationId))
            #expect(answer.status == .answered && answer.answer == "Yes")
            let logged = try await queue.call(AppCommands.diagnostics, DiagnosticsRequest(category: "operator"))
            #expect(logged.map(\.code) == ["OPERATOR_ANSWERED", "OPERATOR_ASKED"])

            let late = try await queue.call(OperatorCommands.ask, OperatorQuestion(question: "Anyone?", answerTimeoutMs: 1_000))
            _ = try await queue.call(AppCommands.wait, WaitRequest(condition: "lifecycle.ended", scope: "app",
                                                                   arguments: ["operationId": .string(late.operationId.uuidString)]))
            #expect(try await queue.call(OperatorCommands.answer, OperatorAnswerRequest(operationId: late.operationId)).status == .unanswered)
            #expect(try await queue.call(OperationCommands.status, OperationStatusRequest(operationId: late.operationId)).state == .failed)
        }
    }

    // MARK: 14 · Experiments

    @Test func experimentsRecordTheirRunsAndRespectReadOnlySessions() async throws {
        try await QueueHost.run { queue in
            let result = try await queue.call(ExperimentCommands.run, ExperimentRequest(experimentId: "probe.count", arguments: ["of": "map"]))
            #expect(result.fields["count"] == 2)
            let logged = try await queue.call(AppCommands.diagnostics, DiagnosticsRequest(category: "experiment"))
            #expect(logged.first?.message == #"inputs={"of":"map"} results={"count":2}"#)
            let capabilities = try #require(try await queue.client.capabilities().result)
            #expect(capabilities.experiments?.map(\.id) == ["probe.count", "probe.reset"])
            #expect(capabilities.invariants == ["queue.mapConsistent"])
            #expect(capabilities.features?.contains("operations.status") == true && capabilities.features?.contains("ui.perform") == true)
            #expect(capabilities.diagnosticCategories.contains("invariant") && capabilities.diagnosticCategories.contains("operator"))
        }
        try await QueueHost.run(allowMutations: false) { queue in
            _ = try await queue.call(ExperimentCommands.run, ExperimentRequest(experimentId: "probe.count", arguments: ["of": "queue"]))
            let denied = await queue.failure { try await queue.call(ExperimentCommands.run, ExperimentRequest(experimentId: "probe.reset")) }
            #expect(denied?.code == .permissionDenied)
            let capabilities = try #require(try await queue.client.capabilities().result)
            #expect(capabilities.experiments?.map(\.id) == ["probe.count"])
            #expect(capabilities.features?.contains("ui.perform") != true)
            let privacy = try await queue.call(PrivacyCommands.status, EmptyParameters())
            #expect(!privacy.probes.isEmpty)
        }
    }

    // MARK: 8 · Recipes

    @Test func recipesRunBurstsAndReportTheFailingStep() async throws {
        try await QueueHost.run { queue in
            let output = FileManager.default.temporaryDirectory.appending(path: "adk-recipes-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: output) }
            let runner = RecipeRunner(client: queue.client, output: output)
            var passing = Recipe(name: "queue", fixture: "quick-v1", steps: [
                ["burst": [["action": "queue.toggle", "args": ["names": ["Downloads"]]],
                           ["action": "queue.toggle", "args": ["names": ["Desktop"]]],
                           ["action": "queue.toggle", "args": ["names": ["Downloads"]]]]],
                ["wait": "queueCount=1"],
                ["assert": ["field": "queued", "contains": "{{name}}"]],
                ["assert": ["field": "queueCount", "atLeast": 1]],
                ["assert": ["field": "stale", "equals": []]],
                ["perform": "set", "id": "detail", "value": 3],
                ["assert": ["field": "detail", "equals": 3]],
                ["assert": ["element": ["id": "detail"], "numericValue": 3]],
            ])
            passing.repeat = 3
            passing.rounds = [["name": "Desktop"]]
            passing.invariants = "hold"
            passing.scope = "app"
            let report = await runner.run(passing)
            #expect(report.passed, "\(String(describing: report.failure))")
            #expect(report.rounds == 3 && report.bursts.count == 3)
            let burst = try #require(report.bursts.first)
            #expect(burst.gapsMs.count == 2 && burst.gapsMs.allSatisfy { $0 < 50 })
            #expect(burst.revisionAfter.map { $0 - (burst.revisionBefore ?? 0) } == 3, "Each burst step is one revision; nothing waited in between.")

            var seeded = Recipe(name: "seeded", fixture: "quick-v1", steps: [
                ["action": "map.bug", "args": ["enabled": true]],
                ["action": "queue.toggle", "args": ["names": ["Desktop"]]],
                ["assert": ["field": "stale", "equals": []]],
            ])
            seeded.scope = "app"
            let failed = await runner.run(seeded)
            #expect(!failed.passed)
            let failure = try #require(failed.failure)
            #expect(failure.step == "3" && failure.kind == "assert")
            #expect(failure.expected == [] && failure.observed == ["Desktop"])
            #expect(failure.revision != nil)
            let snapshot = try #require(failure.snapshot)
            #expect(FileManager.default.fileExists(atPath: snapshot + "/state.json"))
            #expect(FileManager.default.fileExists(atPath: snapshot + "/capture.png"))
            _ = try await queue.call(AppCommands.invoke, ActionRequest(actionId: "map.bug", arguments: ["enabled": false]))
        }
    }
}
