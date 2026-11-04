import AppKit

@MainActor
final class DocumentWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "Draft")
    private(set) var selectedDocumentID = "draft"
    /// Called after the selection changes. Testing builds use it to record a bridge event.
    var onSelectionChange: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "AppKit Documents"
        window.identifier = NSUserInterfaceItemIdentifier("documents")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let draft = NSButton(title: "Draft", target: self, action: #selector(selectDraft))
        draft.setAccessibilityIdentifier("documents.draft")
        let review = NSButton(title: "Review", target: self, action: #selector(selectReview))
        review.setAccessibilityIdentifier("documents.review")
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("documents.selected")
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("documents.close")

        let stack = NSStackView(views: [titleLabel, draft, review])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectDraft() { select(id: "draft", title: "Draft") }
    @objc private func selectReview() { select(id: "review", title: "Review") }

    private func select(id: String, title: String) {
        guard selectedDocumentID != id else { return }
        selectedDocumentID = id
        titleLabel.stringValue = title
        onSelectionChange?()
    }
}

@main
@MainActor
final class DocumentApp: NSObject, NSApplicationDelegate {
    private let documents = DocumentWindowController()
    #if AGENT_DEVKIT
    private let bridge = TestingBridge()
    #endif

    static func main() {
        let app = NSApplication.shared
        let delegate = DocumentApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        documents.showWindow(nil)
        documents.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        #if AGENT_DEVKIT
        bridge.start(controller: documents)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    #if AGENT_DEVKIT
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.terminate(sender)
    }
    #endif
}
