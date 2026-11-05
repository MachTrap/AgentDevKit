import AgentDevKitCore
import AppKit
import ApplicationServices
import Foundation

/// In-process window capture and accessibility inspection. The app reads its own windows on the
/// main actor, so no Screen Recording or Accessibility permission is needed.
@MainActor
enum UIInspection {
    nonisolated static let maxElements = 3_000
    nonisolated static let maxValueLength = 200

    nonisolated static func commands<Adapter: AgentAdapter>(
        adapter: Adapter, runtime: AgentRuntime, access: UIAccess, maxResponseBytes: Int
    ) -> [AppCommand] {
        var commands: [AppCommand] = []
        let window = Schema.string(maxLength: 256)
        if access.contains(.capture) {
            commands.append(AppCommand(UICommands.capture, parameters: ObjectSchema([
                "windowId": window, "format": .string(maxLength: 8, oneOf: ["png", "jpeg"]),
                "maxDimension": .integer(minimum: 64, maximum: 4_096), "method": .string(maxLength: 16, oneOf: ["composite", "display"]),
            ])) { input, _ in
                try capture(input, window: adapter.window(for: input.windowId), revision: runtime.revision,
                            budget: maxResponseBytes)
            })
        }
        if access.contains(.tree) {
            commands.append(AppCommand(UICommands.tree, parameters: ObjectSchema([
                "windowId": window, "identifierPrefix": .string(maxLength: 256), "onlyIdentified": .boolean,
                "maxDepth": .integer(minimum: 1, maximum: 60), "limit": .integer(minimum: 1, maximum: Int64(maxElements)),
                "source": .string(maxLength: 16, oneOf: ["accessibility", "appkit", "views"]),
            ])) { input, _ in
                let target = try require(adapter.window(for: input.windowId))
                if input.source == "views" {
                    return views(target, request: input, revision: runtime.revision)
                }
                if input.source == "appkit" {
                    return try tree(input, window: target, secrets: adapter.secretValues(), revision: runtime.revision)
                }
                let secrets = adapter.secretValues().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                // The system accessibility API sees the same tree as VoiceOver and XCUITest, including SwiftUI
                // content that is only built once an accessibility client asks for it. The first query after a
                // change may build nodes rather than report them, so warm up, let the main run loop turn, then read.
                _ = AccessibilityClient.tree(window: target, request: TreeRequest(limit: 1), secrets: [])
                try? await Task.sleep(for: .milliseconds(40))
                let elements = AccessibilityClient.tree(window: target, request: input, secrets: secrets)
                let size = target.contentView?.bounds.size ?? .zero
                if let elements {
                    return UITree(windowId: target.identifier?.rawValue, title: target.title, size: [Double(size.width), Double(size.height)],
                                  elements: elements.list, truncated: elements.truncated, revision: runtime.revision)
                }
                return try tree(input, window: target, secrets: secrets, revision: runtime.revision)
            })
        }
        if access.contains(.press) {
            commands.append(AppCommand(UICommands.press, parameters: ObjectSchema([
                "identifier": .string(maxLength: 256), "windowId": window, "index": .integer(minimum: 0, maximum: 100),
            ], required: ["identifier"])) { input, _ in
                let target = try require(adapter.window(for: input.windowId))
                var outcome = AccessibilityClient.press(window: target, identifier: input.identifier, index: input.index ?? 0)
                if case .notFound = outcome {
                    // SwiftUI may have built the element's accessibility node during that first search.
                    try? await Task.sleep(for: .milliseconds(60))
                    outcome = AccessibilityClient.press(window: target, identifier: input.identifier, index: input.index ?? 0)
                }
                switch outcome {
                case .pressed(let role):
                    // Let the action's state changes land before reporting the revision.
                    try? await Task.sleep(for: .milliseconds(50))
                    return PressResult(identifier: input.identifier, role: role, revision: runtime.revision)
                case .disabled:
                    throw Failure(.notReady, "The element is disabled.", retryable: true, details: ["field": "identifier"])
                case .unsupported:
                    throw Failure(.notReady, "The element does not support pressing.", details: ["field": "identifier"])
                case .notFound:
                    throw Failure(.notReady, "No element has this accessibility identifier.", retryable: true, details: ["field": "identifier"])
                case .unavailable:
                    return try await press(input, window: target, runtime: runtime)
                }
            })
        }
        return commands
    }

    // MARK: Windows

    /// Exact identifier, then identifier prefix, then title; with no ID, the key, main or first visible window.
    static func defaultWindow(_ windowId: String?) -> NSWindow? {
        let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.contentView != nil }
        guard let windowId, !windowId.isEmpty else {
            return NSApp.keyWindow.flatMap { windows.contains($0) ? $0 : nil }
                ?? NSApp.mainWindow.flatMap { windows.contains($0) ? $0 : nil }
                ?? windows.first { $0.canBecomeMain } ?? windows.first
        }
        return windows.first { $0.identifier?.rawValue == windowId }
            ?? windows.first { $0.identifier?.rawValue.hasPrefix(windowId) == true }
            ?? windows.first { $0.title == windowId }
    }

    static func require(_ window: NSWindow?) throws -> NSWindow {
        guard let window else {
            throw Failure(.notReady, "No visible window matches.", retryable: true, details: ["field": "windowId"])
        }
        return window
    }

    // MARK: Capture

    static func capture(_ input: CaptureRequest, window: NSWindow?, revision: UInt64, budget: Int) throws -> WindowCapture {
        let window = try require(window)
        // The theme frame includes the title bar and toolbar, not just the content view.
        guard let view = window.contentView?.superview ?? window.contentView else {
            throw Failure(.notReady, "The window has no content to render.", retryable: true)
        }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1, let source = input.method == "display" ? displayed(view) : composited(view, window: window) else {
            throw Failure(.notReady, "The window has no visible size.", retryable: true)
        }

        // Base64 adds a third, and the envelope needs room.
        let byteBudget = max(16_384, Int(Double(budget) * 0.72) - 2_048)
        var longest = Double(input.maxDimension ?? 1_600)
        var format = input.format ?? "png"
        for attempt in 0..<8 {
            let scale = min(1, longest / Double(max(source.pixelsWide, source.pixelsHigh)))
            let width = max(1, Int(Double(source.pixelsWide) * scale))
            let height = max(1, Int(Double(source.pixelsHigh) * scale))
            let image = resized(source, width: width, height: height)
            let quality = format == "jpeg" ? max(0.45, 0.85 - Double(attempt) * 0.1) : 1
            let data = format == "jpeg"
                ? image.representation(using: .jpeg, properties: [.compressionFactor: quality])
                : image.representation(using: .png, properties: [:])
            if let data, data.count <= byteBudget {
                return WindowCapture(windowId: window.identifier?.rawValue, title: window.title, width: width, height: height,
                                     scale: Double(width) / bounds.width, format: format, data: data.base64EncodedString(),
                                     bytes: data.count, revision: revision)
            }
            // Too large: try JPEG first, then a smaller image.
            if format == "png" { format = "jpeg" } else { longest *= 0.75 }
        }
        throw Failure(.responseTooLarge, "The capture does not fit the session's response limit.", details: ["field": "maxDimension"])
    }

    /// AppKit drawing. Misses content hosted in glass effect views.
    private static func displayed(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// AppKit drawing of the window, then the content of every glass effect view drawn in place.
    /// AppKit drawing skips glass content, which the window server composites, so it is drawn
    /// separately over an approximation of the glass. Refraction and blur are not reproduced.
    private static func composited(_ view: NSView, window: NSWindow) -> NSBitmapImageRep? {
        let base: NSBitmapImageRep?
        if #available(macOS 26.0, *) { base = compositedGlass(view, window: window) }
        else { base = displayed(view).flatMap { canvas(like: $0, window: window) } }
        guard let base else { return nil }
        // A sheet is its own window; draw it where it appears over its parent.
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let image = composited(sheetView, window: sheet), let context = NSGraphicsContext(bitmapImageRep: base) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let frame = NSRect(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY,
                               width: sheet.frame.width, height: sheet.frame.height)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(origin: .zero, size: base.size).fill(using: .sourceOver)
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        return base
    }

    /// A canvas filled with the window background, so areas without their own background are not transparent.
    private static func canvas(like source: NSBitmapImageRep, window: NSWindow) -> NSBitmapImageRep? {
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The size in points must be set before the context exists, so drawing uses points.
        canvas.size = source.size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            (window.backgroundColor ?? .windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: source.size).fill()
        }
        source.draw(in: NSRect(origin: .zero, size: source.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    @available(macOS 26.0, *)
    private static func compositedGlass(_ view: NSView, window: NSWindow) -> NSBitmapImageRep? {
        guard let drawn = displayed(view), let base = canvas(like: drawn, window: window),
              let context = NSGraphicsContext(bitmapImageRep: base) else { return nil }
        // Drawing into the representation uses its size in points, not pixels.
        let scale: CGFloat = 1
        var glass: [NSGlassEffectView] = []
        func find(_ node: NSView) {
            if let effect = node as? NSGlassEffectView, !effect.isHidden, effect.alphaValue > 0 { glass.append(effect); return }
            for child in node.subviews where !child.isHidden { find(child) }
        }
        find(view)
        func place(_ frame: NSRect) -> NSRect {
            let y = view.isFlipped ? view.bounds.height - frame.maxY : frame.minY
            return NSRect(x: frame.minX * scale, y: y * scale, width: frame.width * scale, height: frame.height * scale)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for effect in glass {
            // AppKit glass hosts its content in `contentView`; SwiftUI glass may add plain subviews.
            let parts = effect.contentView.map { [$0] } ?? effect.subviews.filter { !$0.isHidden }
            let shape = place(effect.convert(effect.bounds, to: view))
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                let radius = effect.cornerRadius * scale
                let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
                (effect.tintColor ?? NSColor.windowBackgroundColor).withAlphaComponent(0.92).setFill()
                path.fill()
                NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
                path.lineWidth = max(1, scale * 0.5)
                path.stroke()
            }
            for content in parts where content.bounds.width >= 1 && content.bounds.height >= 1 {
                guard let image = displayed(content) else { continue }
                image.draw(in: place(content.convert(content.bounds, to: view)), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
        }
        // Tables and outlines, such as SwiftUI lists, draw their rows outside AppKit's display pass.
        // Draw each visible row in place, clipped to its scroll view.
        var tables: [NSTableView] = []
        func findTables(_ node: NSView) {
            if let table = node as? NSTableView { tables.append(table); return }
            for child in node.subviews where !child.isHidden { findTables(child) }
        }
        findTables(view)
        for table in tables {
            let visible = table.visibleRect
            let clip = place(table.convert(visible, to: view))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            let rows = table.rows(in: visible)
            for row in rows.location..<(rows.location + rows.length) {
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: false), let image = displayed(rowView) else { continue }
                image.draw(in: place(rowView.convert(rowView.bounds, to: view)), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return base
    }

    private static func resized(_ source: NSBitmapImageRep, width: Int, height: Int) -> NSBitmapImageRep {
        guard width != source.pixelsWide || height != source.pixelsHigh,
              let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    // MARK: Accessibility tree

    static func tree(_ input: TreeRequest, window: NSWindow?, secrets: [String], revision: UInt64) throws -> UITree {
        let window = try require(window)
        let limit = input.limit ?? 800
        let maxDepth = input.maxDepth ?? 40
        let secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var elements: [UIElement] = []
        var truncated = false
        walk(window, window: window, depth: 0) { element, depth in
            guard elements.count < limit else {
                truncated = true
                return false
            }
            guard depth <= maxDepth else { return false }
            if let summary = describe(element, window: window, depth: depth, secrets: secrets),
               input.onlyIdentified != true || summary.identifier != nil,
               input.identifierPrefix.map({ summary.identifier?.hasPrefix($0) == true }) ?? true {
                elements.append(summary)
            }
            return true
        }
        let size = window.contentView?.bounds.size ?? .zero
        return UITree(windowId: window.identifier?.rawValue, title: window.title, size: [Double(size.width), Double(size.height)],
                      elements: elements, truncated: truncated, revision: revision)
    }

    /// Visits accessibility children depth first. `visit` returns false to skip an element's children.
    /// Ignored containers are flattened, so depth counts only reported elements.
    static func walk(_ root: NSWindow, window: NSWindow, depth: Int, visit: (AXNode, Int) -> Bool) {
        var seen = Set<ObjectIdentifier>()
        func descend(_ node: AXNode, depth: Int) {
            guard seen.insert(ObjectIdentifier(node.object)).inserted, seen.count < 20_000 else { return }
            let reported = node.isReported
            if reported, !visit(node, depth) { return }
            for child in node.children { descend(child, depth: reported ? depth + 1 : depth) }
        }
        // Start from the frame view, which holds the title bar and content even before the window
        // is registered with the accessibility server.
        let start: [AXNode] = root.contentView?.superview.map { AXNode($0).children } ?? AXNode(root).children
        for child in start { descend(child, depth: depth) }
    }

    private static func describe(_ node: AXNode, window: NSWindow, depth: Int, secrets: [String]) -> UIElement? {
        guard let role = node.role else { return nil }
        let subrole = node.subrole
        let identifier = node.identifier
        func clean(_ text: String?) -> String? {
            guard var text, !text.isEmpty else { return nil }
            for secret in secrets { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
            return text.count > maxValueLength ? String(text.prefix(maxValueLength)) + "…" : text
        }
        let label = clean(node.label) ?? clean(node.title)
        let value: String? = subrole == NSAccessibility.Subrole.secureTextField.rawValue ? nil : clean(node.value)
        // Accessibility frames are in screen coordinates with a bottom-left origin.
        let screen = node.frame
        let origin = window.frame
        let frame = [screen.minX - origin.minX, origin.maxY - screen.maxY, screen.width, screen.height].map { (Double($0) * 10).rounded() / 10 }
        return UIElement(role: role, subrole: subrole, identifier: identifier, label: label, value: value, frame: frame,
                         enabled: node.enabled, focused: node.focused, selected: node.selected, depth: depth)
    }

    /// The AppKit view hierarchy: class names, frames and visibility, for diagnosing layout and captures.
    /// Values are never read, so no app content is included.
    static func views(_ window: NSWindow, request: TreeRequest, revision: UInt64) -> UITree {
        let limit = request.limit ?? 800
        let maxDepth = request.maxDepth ?? 40
        var elements: [UIElement] = []
        var truncated = false
        func visit(_ view: NSView, depth: Int) {
            guard depth <= maxDepth else { return }
            guard elements.count < limit else { truncated = true; return }
            let frame = view.convert(view.bounds, to: nil)
            let height = window.contentView?.superview?.bounds.height ?? frame.maxY
            let type = String(describing: Swift.type(of: view))
            let name = type.firstIndex(of: "<").map { String(type[..<$0]) } ?? type
            let identifier = view.identifier?.rawValue ?? view.accessibilityIdentifier()
            elements.append(UIElement(role: name, subrole: view.layer.map { String(describing: Swift.type(of: $0)) }, identifier: identifier.isEmpty ? nil : identifier,
                                      label: view.isHidden ? "hidden" : (view.alphaValue < 1 ? "alpha \(view.alphaValue)" : nil), value: nil,
                                      frame: [frame.minX, height - frame.maxY, frame.width, frame.height].map { (Double($0) * 10).rounded() / 10 },
                                      enabled: true, focused: window.firstResponder === view, selected: false, depth: depth))
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        if let root = window.contentView?.superview { visit(root, depth: 0) }
        let size = window.contentView?.bounds.size ?? .zero
        return UITree(windowId: window.identifier?.rawValue, title: window.title, size: [Double(size.width), Double(size.height)],
                      elements: elements, truncated: truncated, revision: revision)
    }

    // MARK: Press

    static func press(_ input: PressRequest, window: NSWindow?, runtime: AgentRuntime) async throws -> PressResult {
        let window = try require(window)
        var matches: [AXNode] = []
        walk(window, window: window, depth: 0) { element, _ in
            if element.identifier == input.identifier { matches.append(element) }
            return matches.count <= (input.index ?? 0)
        }
        let index = input.index ?? 0
        guard matches.indices.contains(index) else {
            throw Failure(.notReady, "No element has this accessibility identifier.", retryable: true, details: ["field": "identifier"])
        }
        let element = matches[index]
        guard element.enabled else {
            throw Failure(.notReady, "The element is disabled.", retryable: true, details: ["field": "identifier"])
        }
        guard element.press() else {
            throw Failure(.notReady, "The element does not support pressing.", details: ["field": "identifier"])
        }
        // Let the action's state changes land before reporting the revision.
        await Task.yield()
        return PressResult(identifier: input.identifier, role: element.role ?? "", revision: runtime.revision)
    }
}

/// One accessibility object in the fallback in-process walk, for objects that adopt `NSAccessibilityProtocol`.
/// A cell-based control and its cell form one node: the control owns identity, identifier, frame and
/// action; the cell often carries the role, label and value.
@MainActor
struct AXNode {
    let object: NSObject
    private let primary: (any NSAccessibilityProtocol)?
    private let control: NSControl?

    init(_ object: NSObject) {
        if let cell = object as? NSCell, let control = cell.controlView as? NSControl, control.cell === cell {
            self.object = control
            self.control = control
            primary = cell
        } else if let control = object as? NSControl, !(object is NSTableView), let cell = control.cell, control.accessibilityRole() == nil {
            self.object = control
            self.control = control
            primary = cell
        } else {
            self.object = object
            // Tables and outlines are containers, not leaf controls.
            control = object is NSTableView ? nil : object as? NSControl
            primary = object as? any NSAccessibilityProtocol
        }
    }

    private var view: (any NSAccessibilityProtocol)? { control.map { $0 as any NSAccessibilityProtocol } }

    var role: String? {
        let role = primary?.accessibilityRole()?.rawValue ?? view?.accessibilityRole()?.rawValue
        return role == NSAccessibility.Role.unknown.rawValue ? nil : role
    }
    var subrole: String? { primary?.accessibilitySubrole()?.rawValue ?? view?.accessibilitySubrole()?.rawValue }
    var identifier: String? {
        [control?.accessibilityIdentifier(), primary?.accessibilityIdentifier(), (object as? NSView)?.identifier?.rawValue]
            .compactMap { $0 }.first { !$0.isEmpty }
    }
    var label: String? { primary?.accessibilityLabel() ?? view?.accessibilityLabel() }
    var title: String? { primary?.accessibilityTitle() ?? view?.accessibilityTitle() }
    var value: String? { AccessibilityClient.text(primary?.accessibilityValue() ?? view?.accessibilityValue()) }
    var frame: NSRect {
        if let control, let window = control.window {
            return window.convertToScreen(control.convert(control.bounds, to: nil))
        }
        return primary?.accessibilityFrame() ?? .zero
    }
    var enabled: Bool { control?.isEnabled ?? primary?.isAccessibilityEnabled() ?? true }
    var focused: Bool { primary?.isAccessibilityFocused() ?? false }
    var selected: Bool { primary?.isAccessibilitySelected() ?? false }

    /// Reported in the tree: real elements, plus ignored containers that carry an identifier.
    var isReported: Bool {
        role != nil && ((primary?.isAccessibilityElement() ?? false) || control != nil || identifier != nil)
    }

    var children: [AXNode] {
        if control != nil { return [] }
        var raw = primary?.accessibilityChildren() ?? []
        if raw.isEmpty { raw = primary?.accessibilityVisibleRows() ?? primary?.accessibilityRows() ?? [] }
        var children = raw.compactMap { ($0 as? NSObject).map(AXNode.init) }
        // AppKit views can hold content that is not yet in their accessibility children.
        if children.isEmpty, let view = object as? NSView { children = view.subviews.map(AXNode.init) }
        return children
    }

    func press() -> Bool {
        // Send the control's action directly. `performClick` would spin a nested run loop for its
        // highlight, which re-enters the main queue while a Swift task is running on it.
        if let control, let action = control.action {
            return control.sendAction(action, to: control.target)
        }
        return primary?.accessibilityPerformPress() == true || view?.accessibilityPerformPress() == true
    }
}

/// Reads the app's own accessibility tree through the system API, as an assistive app would.
/// A process may query itself without Accessibility permission. For its own PID the system calls
/// the elements directly on the calling thread, so this must run on the main actor.
@MainActor
enum AccessibilityClient {
    struct Elements: Sendable {
        let list: [UIElement]
        let truncated: Bool
    }

    enum PressOutcome: Sendable {
        case pressed(role: String)
        case disabled, unsupported, notFound
        /// The accessibility API is not available to this process.
        case unavailable
    }

    private static var attributes: [String] { [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute,
                                     kAXTitleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                     kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute,
                                     kAXVisibleRowsAttribute] }

    private struct Node {
        let element: AXUIElement
        let values: [String: CFTypeRef]

        func string(_ name: String) -> String? {
            guard let value = values[name] else { return nil }
            return AccessibilityClient.text(value)
        }
        func bool(_ name: String, _ fallback: Bool) -> Bool { (values[name] as? Bool) ?? fallback }
        /// Children, or for outlines and tables that report none, their visible rows.
        var children: [AXUIElement] {
            let children = (values[kAXChildrenAttribute] as? [AXUIElement]) ?? []
            return children.isEmpty ? (values[kAXVisibleRowsAttribute] as? [AXUIElement]) ?? [] : children
        }
        var frame: CGRect {
            var point = CGPoint.zero
            var size = CGSize.zero
            if let value = values[kAXPositionAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &point)
            }
            if let value = values[kAXSizeAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            return CGRect(origin: point, size: size)
        }
    }

    private static func read(_ element: AXUIElement) -> Node? {
        var raw: CFArray?
        let names = attributes
        guard AXUIElementCopyMultipleAttributeValues(element, names.map { $0 as CFString } as CFArray, [], &raw) == .success,
              let values = raw as? [CFTypeRef], values.count == names.count else { return nil }
        var map: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, values) {
            // Missing attributes come back as AXValue errors.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            map[name] = value
        }
        return Node(element: element, values: map)
    }

    /// The accessibility element of a window, matched by its frame, then by title. Accessibility
    /// frames use a top-left origin on the primary screen; AppKit frames use a bottom-left origin.
    private static func window(_ target: NSWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement], !windows.isEmpty else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? target.frame.maxY
        let expected = CGRect(x: target.frame.minX, y: height - target.frame.maxY, width: target.frame.width, height: target.frame.height)
        var titled: AXUIElement?
        for window in windows {
            guard let node = read(window) else { continue }
            let frame = node.frame
            if abs(frame.minX - expected.minX) < 2, abs(frame.minY - expected.minY) < 2,
               abs(frame.width - expected.width) < 2, abs(frame.height - expected.height) < 2 { return window }
            if titled == nil, let title = node.string(kAXTitleAttribute), !target.title.isEmpty, title.hasPrefix(target.title) { titled = window }
        }
        return titled ?? (windows.count == 1 ? windows.first : nil)
    }

    nonisolated static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func tree(window target: NSWindow, request: TreeRequest, secrets: [String]) -> Elements? {
        guard let window = window(target), let root = read(window) else { return nil }
        let origin = root.frame.origin
        let limit = request.limit ?? 800
        let maxDepth = request.maxDepth ?? 40
        var list: [UIElement] = []
        var truncated = false
        var visited = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        /// Outlines report the same cells through rows and columns; list each element once.
        func firstVisit(_ element: AXUIElement) -> Bool {
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { return false }
            seen[hash, default: []].append(element)
            return true
        }
        func clean(_ text: String?) -> String? {
            guard var text, !text.isEmpty else { return nil }
            for secret in secrets { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
            return text.count > UIInspection.maxValueLength ? String(text.prefix(UIInspection.maxValueLength)) + "…" : text
        }
        func visit(_ node: Node, depth: Int) {
            guard !truncated else { return }
            visited += 1
            guard visited < 20_000 else { truncated = true; return }
            for child in node.children where firstVisit(child) {
                guard let childNode = read(child) else { continue }
                if list.count >= limit {
                    truncated = true
                    return
                }
                let identifier = childNode.string(kAXIdentifierAttribute).flatMap { $0.isEmpty ? nil : $0 }
                let keep = (request.onlyIdentified != true || identifier != nil)
                    && (request.identifierPrefix.map { identifier?.hasPrefix($0) == true } ?? true)
                if keep, let role = childNode.string(kAXRoleAttribute) {
                    let subrole = childNode.string(kAXSubroleAttribute)
                    let frame = childNode.frame
                    let value = subrole == kAXSecureTextFieldSubrole ? nil : clean(childNode.string(kAXValueAttribute))
                    list.append(UIElement(
                        role: role, subrole: subrole, identifier: identifier,
                        label: clean(childNode.string(kAXDescriptionAttribute)) ?? clean(childNode.string(kAXTitleAttribute)),
                        value: value,
                        frame: [frame.minX - origin.x, frame.minY - origin.y, frame.width, frame.height].map { (Double($0) * 10).rounded() / 10 },
                        enabled: childNode.bool(kAXEnabledAttribute, true), focused: childNode.bool(kAXFocusedAttribute, false),
                        selected: childNode.bool(kAXSelectedAttribute, false), depth: depth))
                }
                if depth < maxDepth { visit(childNode, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return Elements(list: list, truncated: truncated)
    }

    static func press(window target: NSWindow, identifier: String, index: Int) -> PressOutcome {
        guard let window = window(target), let root = read(window) else { return .unavailable }
        var matches: [Node] = []
        var visited = 0
        func search(_ node: Node) {
            for child in node.children where matches.count <= index && visited < 20_000 {
                visited += 1
                guard let childNode = read(child) else { continue }
                if childNode.string(kAXIdentifierAttribute) == identifier { matches.append(childNode) }
                search(childNode)
            }
        }
        search(root)
        guard matches.indices.contains(index) else { return .notFound }
        let target = matches[index]
        guard target.bool(kAXEnabledAttribute, true) else { return .disabled }
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else { return .unsupported }
        return .pressed(role: target.string(kAXRoleAttribute) ?? "")
    }
}
