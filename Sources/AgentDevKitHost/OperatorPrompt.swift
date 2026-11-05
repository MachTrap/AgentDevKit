import AgentDevKitCore
import AppKit
import Foundation

/// A Testing-only floating panel in which a person answers an agent's question. It is labelled as such,
/// lives only in the host library (never linked into Release), and is served only to mutation sessions.
@MainActor
final class OperatorPrompt: NSObject, NSWindowDelegate {
    static let identifierPrefix = "agentdevkit.operator"
    static let title = "Agent question (Testing build)"

    private let panel: NSPanel
    private let notes: NSTextField?
    private let options: [String]
    private var continuation: CheckedContinuation<(answer: String, notes: String?)?, Never>?

    init(id: UUID, question: String, options: [String], allowNotes: Bool) {
        self.options = options
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                        styleMask: [.titled, .utilityWindow, .closable], backing: .buffered, defer: false)
        panel.title = Self.title
        panel.identifier = NSUserInterfaceItemIdentifier("\(Self.identifierPrefix).\(id.uuidString.prefix(8).lowercased())")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: question)
        label.font = .systemFont(ofSize: 13)
        label.setAccessibilityIdentifier("operator.question")
        let badge = NSTextField(labelWithString: "Asked by an agent through AgentDevKit. Testing builds only.")
        badge.font = .systemFont(ofSize: 11)
        badge.textColor = .secondaryLabelColor
        notes = allowNotes ? NSTextField(string: "") : nil
        notes?.placeholderString = "Notes (optional)"
        notes?.setAccessibilityIdentifier("operator.notes")
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        super.init()
        for (index, title) in options.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("operator.option.\(index)")
            if index == 0 { button.keyEquivalent = "\r" }
            buttons.addArrangedSubview(button)
        }
        let stack = NSStackView(views: [badge, label] + (notes.map { [$0] } ?? []) + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 388),
        ])
        if let notes { notes.widthAnchor.constraint(equalToConstant: 388).isActive = true }
        panel.contentView = content
        panel.delegate = self
    }

    /// Shows the panel and returns the chosen option, or nil when the panel closed or the timeout passed.
    func ask(timeout: Duration) async -> (answer: String, notes: String?)? {
        panel.center()
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.finish(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    @objc private func choose(_ sender: NSButton) {
        let typed = notes?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish((options[sender.tag], typed?.isEmpty == false ? String(typed!.prefix(2_000)) : nil))
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ value: (answer: String, notes: String?)?) {
        guard let continuation else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        self.continuation = nil
        panel.delegate = nil
        panel.orderOut(nil)
        continuation.resume(returning: value)
    }
}
