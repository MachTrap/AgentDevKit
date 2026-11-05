import AgentDevKitCore
import AppKit
import ApplicationServices
import Foundation

/// Locates elements by identifier, path, role and label, and performs typed accessibility operations on them.
/// These prove that a control exists, is enabled and responds; they do not prove pointer hit testing.
@MainActor
enum UIOperations {
    nonisolated static let operations = ["set", "choose", "expand", "collapse", "press", "increment", "decrement", "dismiss"]

    struct Located {
        let node: AccessibilityClient.Node
        let role: String
        let path: String
        let window: NSWindow
        let origin: CGPoint
    }

    enum PressOutcome {
        case pressed(role: String, path: String?)
        /// The accessibility API is not available to this process.
        case unavailable
    }

    /// Finds exactly one element. Returns nil when the accessibility API is unavailable.
    /// Throws NOT_READY when nothing matches and AMBIGUOUS_ELEMENT when several do and no index was given.
    static func locate(_ locator: ElementLocator, in windows: [NSWindow]) throws -> Located? {
        guard !locator.isEmpty else {
            throw Failure(.invalidParams, "Pass identifier, path, or role and label.", details: ["field": "identifier"])
        }
        let wantedPath = locator.path.map(AccessibilityClient.normalizedPath)
        let wantedRole = locator.role.map(AccessibilityClient.roleName)
        let wantedLabel = locator.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [Located] = []
        var identifiers: Set<String> = []
        var available = false
        for window in windows {
            guard let origin = AccessibilityClient.window(window).flatMap(AccessibilityClient.read)?.frame.origin else { continue }
            let walked = AccessibilityClient.walk(window: window) { visit in
                if let identifier = visit.node.identifier, identifiers.count < 400 { identifiers.insert(identifier) }
                guard matches.count <= 100 else { return false }
                if let identifier = locator.identifier, visit.node.identifier != identifier { return true }
                if let wantedPath, AccessibilityClient.normalizedPath(visit.path) != wantedPath { return true }
                if let wantedRole, AccessibilityClient.roleName(visit.role) != wantedRole,
                   visit.node.string(kAXSubroleAttribute).map(AccessibilityClient.roleName) != wantedRole { return true }
                if let wantedLabel {
                    let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                        .compactMap { visit.node.string($0)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    guard texts.contains(wantedLabel) else { return true }
                }
                // A popover is reachable from its own window and from the control that shows it; count it once.
                if !matches.contains(where: { CFEqual($0.node.element, visit.node.element) }) {
                    matches.append(Located(node: visit.node, role: visit.role, path: visit.path, window: window, origin: origin))
                }
                return true
            }
            if walked != nil { available = true }
        }
        guard available else { return nil }
        if let index = locator.index {
            guard matches.indices.contains(index) else { throw notFound(locator, identifiers: identifiers, count: matches.count) }
            return matches[index]
        }
        guard let first = matches.first else { throw notFound(locator, identifiers: identifiers, count: 0) }
        guard matches.count == 1 else {
            throw Failure(.ambiguousElement, "\(matches.count) elements match \(locator.summary). Pass --path or --index.", details: [
                "paths": .array(matches.prefix(20).map { .string($0.path) }), "count": .integer(Int64(matches.count)),
                "field": locator.path != nil ? "path" : "identifier",
            ])
        }
        return first
    }

    private static func notFound(_ locator: ElementLocator, identifiers: Set<String>, count: Int) -> Failure {
        if let identifier = locator.identifier, count == 0, locator.path == nil {
            let failure = Failure.unknownName(.notReady, kind: "element identifier", field: "identifier", name: identifier,
                                              valid: Array(identifiers)) { "agentdevctl ui press --id \(NameSuggestions.shellQuoted($0))" }
            return Failure(.notReady, failure.message, retryable: true, details: failure.details)
        }
        return Failure(.notReady, count > 0 ? "Only \(count) elements match \(locator.summary)." : "No element matches \(locator.summary).",
                       retryable: true, details: ["field": locator.path != nil ? "path" : locator.identifier != nil ? "identifier" : "role"])
    }

    /// Locates, retrying once after SwiftUI may have built missing accessibility nodes.
    static func locateRetrying(_ locator: ElementLocator, in windows: [NSWindow]) async throws -> Located? {
        do { return try locate(locator, in: windows) } catch let failure as Failure where failure.code == .notReady {
            try? await Task.sleep(for: .milliseconds(60))
            return try locate(locator, in: windows)
        }
    }

    static func pressNow(_ locator: ElementLocator, in windows: [NSWindow]) throws -> PressOutcome {
        guard let target = try locate(locator, in: windows) else { return .unavailable }
        try requireEnabled(target)
        guard pressElement(target) else {
            throw Failure(.notReady, "The element does not support pressing.", details: ["field": "identifier", "actions": .array(target.node.actions.map(JSONValue.string))])
        }
        return .pressed(role: target.role, path: target.path)
    }

    static func press(_ locator: ElementLocator, in windows: [NSWindow]) async throws -> PressOutcome {
        do { return try pressNow(locator, in: windows) } catch let failure as Failure where failure.code == .notReady && failure.retryable {
            try? await Task.sleep(for: .milliseconds(60))
            return try pressNow(locator, in: windows)
        }
    }

    private static func requireEnabled(_ target: Located) throws {
        guard target.node.bool(kAXEnabledAttribute, true) else {
            throw Failure(.notReady, "The element is disabled.", retryable: true, details: ["field": "identifier", "path": .string(target.path)])
        }
    }

    // MARK: Typed operations

    static func perform(_ input: PerformRequest, in windows: [NSWindow], runtime: AgentRuntime) async throws -> PerformResult {
        if input.operation == "dismiss" { return try await dismiss(input, in: windows, runtime: runtime) }
        let locator = input.locator
        guard let target = try await locateRetrying(locator, in: windows) else {
            throw Failure(.notReady, "The accessibility API is unavailable in this process.")
        }
        try requireEnabled(target)
        let element = target.node.element
        switch input.operation {
        case "press":
            guard pressElement(target) else { try action(kAXPressAction, on: target); break }
        case "increment":
            try step(up: true, on: target)
        case "decrement":
            try step(up: false, on: target)
        case "set":
            guard let value = input.value, value != .null else {
                throw Failure(.invalidParams, "set needs a value.", details: ["field": "value"])
            }
            try set(value, on: target)
        case "choose":
            guard let item = input.item, !item.isEmpty else {
                throw Failure(.invalidParams, "choose needs an item title or identifier.", details: ["field": "item"])
            }
            try await choose(item, on: target)
        case "expand", "collapse":
            try disclose(input.operation == "expand", on: target)
        default:
            throw Failure(.invalidParams, "Unknown operation.", details: ["field": "operation"])
        }
        // Let the control's action and the app's state changes land before reading back.
        try? await Task.sleep(for: .milliseconds(60))
        let after = AccessibilityClient.read(element) ?? target.node
        let secure = after.string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        return PerformResult(operation: input.operation, role: target.role, path: target.path,
                             value: secure ? nil : after.string(kAXValueAttribute).map { ScreenSnapshot.preview($0, maxBytes: 200) },
                             numericValue: secure ? nil : after.number(kAXValueAttribute), revision: runtime.revision)
    }

    /// Closes a sheet, panel, alert or popover without its buttons, for panels whose content another process draws
    /// (open and save panels). `item` is `cancel` (default) or `ok`. Targets `windowId`, else the front-most surface.
    private static func dismiss(_ input: PerformRequest, in windows: [NSWindow], runtime: AgentRuntime) async throws -> PerformResult {
        guard let surface = input.windowId != nil ? windows.first : windows.first(where: { Surfaces.kind($0) != .window }) else {
            throw Failure(.notReady, "No sheet, panel, alert or popover is open.", details: ["field": "windowId"])
        }
        let accept = ["ok", "default", "confirm"].contains(input.item?.lowercased() ?? "cancel")
        let kind = Surfaces.kind(surface)
        if let panel = surface as? NSSavePanel {
            if accept { panel.ok(nil) } else { panel.cancel(nil) }
        } else if let parent = surface.sheetParent {
            parent.endSheet(surface, returnCode: accept ? .OK : .cancel)
        } else if NSApp.modalWindow === surface {
            NSApp.stopModal(withCode: accept ? .OK : .cancel)
            surface.orderOut(nil)
        } else if kind == .window {
            throw Failure(.invalidParams, "dismiss closes sheets, panels, alerts and popovers, not document windows.", details: ["field": "windowId"])
        } else {
            surface.performClose(nil)
            if surface.isVisible { surface.orderOut(nil) }
        }
        try? await Task.sleep(for: .milliseconds(80))
        return PerformResult(operation: "dismiss", role: kind.rawValue, path: Surfaces.id(surface), value: accept ? "ok" : "cancel",
                             numericValue: nil, revision: runtime.revision)
    }

    /// The AppKit control drawn exactly where the element is, if any.
    static func appKitControl(at target: Located) -> NSControl? {
        let frame = target.node.frame
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let root = target.window.contentView?.superview ?? target.window.contentView else { return nil }
        let point = target.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: height - frame.midY))
        var view = root.hitTest(point)
        while let current = view, !(current is NSControl) { view = current.superview }
        guard let control = view as? NSControl, let window = control.window else { return nil }
        let screen = window.convertToScreen(control.convert(control.bounds, to: nil))
        let expected = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        guard abs(screen.midX - expected.midX) < 3, abs(screen.midY - expected.midY) < 3 else { return nil }
        return control
    }

    /// Presses an AppKit button by sending its action, after advancing a checkbox or disclosure state as a click
    /// would. The accessibility press calls `performClick:`, which runs a nested event loop on the main thread
    /// while a bridge task is running there. Other elements, such as SwiftUI controls, use the accessibility press.
    static func pressElement(_ target: Located) -> Bool {
        if let button = appKitControl(at: target) as? NSButton, !(button is NSPopUpButton), let action = button.action {
            guard button.isEnabled else { return false }
            if button.allowsMixedState || [.on, .off].contains(button.state), buttonToggles(button) { button.setNextState() }
            return button.sendAction(action, to: button.target)
        }
        return AXUIElementPerformAction(target.node.element, kAXPressAction as CFString) == .success
    }

    /// Moves a slider or stepper one step. AppKit controls are stepped directly, because their accessibility
    /// increment runs a nested event loop; other controls get the accessibility action.
    static func step(up: Bool, on target: Located) throws {
        switch appKitControl(at: target) {
        case let slider as NSSlider:
            let span = slider.maxValue - slider.minValue
            let increment = slider.numberOfTickMarks > 1 ? span / Double(slider.numberOfTickMarks - 1)
                : slider.altIncrementValue > 0 ? slider.altIncrementValue : span / 20
            slider.doubleValue = min(slider.maxValue, max(slider.minValue, slider.doubleValue + (up ? increment : -increment)))
            if let action = slider.action { slider.sendAction(action, to: slider.target) }
        case let stepper as NSStepper:
            stepper.doubleValue = min(stepper.maxValue, max(stepper.minValue, stepper.doubleValue + (up ? stepper.increment : -stepper.increment)))
            if let action = stepper.action { stepper.sendAction(action, to: stepper.target) }
        default:
            try action(up ? kAXIncrementAction : kAXDecrementAction, on: target)
        }
    }

    /// Checkboxes, radio buttons, disclosure triangles and push-on-push-off buttons change state when clicked.
    private static func buttonToggles(_ button: NSButton) -> Bool {
        let role = button.accessibilityRole()
        return [.checkBox, .radioButton, .disclosureTriangle].contains(role) || button.bezelStyle == .disclosure
            || (button.cell as? NSButtonCell).map { $0.showsStateBy.contains(.contentsCellMask) || $0.showsStateBy.contains(.changeBackgroundCellMask) } == true
    }

    private static func action(_ name: String, on target: Located) throws {
        guard AXUIElementPerformAction(target.node.element, name as CFString) == .success else {
            throw Failure(.notReady, "The element does not support \(AccessibilityClient.actionName(name)).",
                          details: ["field": "operation", "actions": .array(target.node.actions.map(JSONValue.string))])
        }
    }

    private static func current(_ target: Located) -> Double? {
        AccessibilityClient.read(target.node.element)?.number(kAXValueAttribute)
    }

    private static func set(_ value: JSONValue, on target: Located) throws {
        let element = target.node.element
        let settable = target.node.settable(kAXValueAttribute)
        switch value {
        case .bool(let on):
            let now = current(target)
            if let now, (now != 0) == on { return }
            if now != nil || target.node.actions.contains("press") {
                guard pressElement(target) else { try action(kAXPressAction, on: target); break }
            } else if settable {
                guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (on ? 1 : 0) as CFNumber) == .success else {
                    throw Failure(.notReady, "The element rejected the value.", details: ["field": "value"])
                }
            } else {
                throw Failure(.notReady, "The element has no on or off state.", details: ["field": "value"])
            }
        case .integer, .number:
            let goal = value.doubleValue ?? 0
            if let minimum = target.node.number(kAXMinValueAttribute), let maximum = target.node.number(kAXMaxValueAttribute),
               goal < minimum || goal > maximum {
                throw Failure(.invalidParams, "Value is outside \(minimum)…\(maximum).", details: ["field": "value"])
            }
            if settable, AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, goal as CFNumber) == .success,
               let now = current(target), abs(now - goal) < 1e-6 {
                return
            }
            // Steppers and some sliders only move by increments.
            let actions = target.node.actions
            guard actions.contains("increment") || actions.contains("decrement") else {
                throw Failure(.notReady, "The element's value cannot be set or stepped.", details: ["field": "value"])
            }
            var last = current(target)
            for _ in 0..<400 {
                guard let now = last else { break }
                if abs(now - goal) < 1e-6 { return }
                try step(up: now < goal, on: target)
                let next = current(target)
                if next == now { break }
                if let next, (now < goal) != (next < goal), abs(next - goal) > 1e-6 { last = next; break }
                last = next
            }
            guard let reached = current(target), abs(reached - goal) < 1e-6 else {
                throw Failure(.notReady, "The element stopped at \(current(target).map { String($0) } ?? "an unknown value") before reaching the value.",
                              details: ["field": "value"])
            }
        case .string(let text):
            guard settable, AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
                throw Failure(.notReady, "The element's value is not settable.", details: ["field": "value"])
            }
        default:
            throw Failure(.invalidParams, "Value must be a number, boolean or string.", details: ["field": "value"])
        }
    }

    /// Picks a menu item without opening the menu: through the AppKit pop-up button behind the element,
    /// or the element's accessibility menu items.
    private static func choose(_ item: String, on target: Located) async throws {
        let wanted = item.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ title: String?, _ identifier: String?) -> Bool {
            title?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame || identifier == wanted
        }
        if let popup = popUpButton(at: target), let menu = popup.menu {
            let items = menu.items
            guard let index = items.firstIndex(where: { !$0.isSeparatorItem && matches($0.title, $0.identifier?.rawValue) }) else {
                throw Failure.unknownName(.notReady, kind: "menu item", field: "item", name: wanted,
                                          valid: items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.map(\.title))
            }
            guard items[index].isEnabled else { throw Failure(.notReady, "The menu item is disabled.", details: ["field": "item"]) }
            menu.performActionForItem(at: index)
            return
        }
        if target.node.actions.contains("showMenu") || target.role == "AXMenuButton" || target.role == kAXPopUpButtonRole {
            try await openAndPick(wanted, on: target)
            return
        }
        // Accessibility fallback: menu items exposed as children of the element.
        var candidates: [(title: String, element: AXUIElement)] = []
        func collect(_ node: AccessibilityClient.Node, depth: Int) {
            for child in node.children where depth < 3 {
                guard let childNode = AccessibilityClient.read(child) else { continue }
                if childNode.role == kAXMenuItemRole, let title = childNode.string(kAXTitleAttribute) {
                    if matches(title, childNode.identifier) { candidates.insert((title, child), at: 0) } else { candidates.append((title, child)) }
                }
                collect(childNode, depth: depth + 1)
            }
        }
        collect(target.node, depth: 0)
        guard let first = candidates.first, matches(first.title, nil) || candidates.contains(where: { matches($0.title, nil) }) else {
            throw Failure.unknownName(.notReady, kind: "menu item", field: "item", name: wanted, valid: candidates.map(\.title))
        }
        guard AXUIElementPerformAction(first.element, kAXPressAction as CFString) == .success else {
            throw Failure(.notReady, "The menu item does not respond to press.", details: ["field": "item"])
        }
    }

    /// Opens a menu that exists only while shown, such as a SwiftUI `Menu`, picks the item and closes it.
    /// Showing a menu runs a nested tracking loop inside the accessibility call; the pick runs on the main
    /// queue inside that loop, closes the menu, and the item's action runs after the call returns.
    private static func openAndPick(_ wanted: String, on target: Located) async throws {
        MenuTracker.start()
        final class Pick { var menu: NSMenu?; var index: Int?; var titles: [String] = [] }
        let pick = Pick()
        let before = Set(MenuTracker.shared.openMenus.map(ObjectIdentifier.init))
        var attempts = 0
        func poll() {
            attempts += 1
            if let menu = MenuTracker.shared.openMenus.last(where: { !before.contains(ObjectIdentifier($0)) }) {
                pick.menu = menu
                pick.titles = menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.map(\.title)
                pick.index = menu.items.firstIndex {
                    !$0.isSeparatorItem && ($0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame
                                            || $0.identifier?.rawValue == wanted)
                }
                menu.cancelTrackingWithoutAnimation()
                return
            }
            guard attempts < 150 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { MainActor.assumeIsolated { poll() } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { poll() } }
        let action = target.node.actions.contains("showMenu") ? kAXShowMenuAction : kAXPressAction
        guard AXUIElementPerformAction(target.node.element, action as CFString) == .success else {
            throw Failure(.notReady, "The menu did not open.", details: ["field": "item"])
        }
        // Some menus open after the press returns, such as SwiftUI's.
        for _ in 0..<150 where pick.menu == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard let menu = pick.menu else {
            throw Failure(.notReady, "The menu did not report that it opened.", details: ["field": "item"])
        }
        guard let index = pick.index else {
            throw Failure.unknownName(.notReady, kind: "menu item", field: "item", name: wanted, valid: pick.titles)
        }
        guard menu.items[index].isEnabled else { throw Failure(.notReady, "The menu item is disabled.", details: ["field": "item"]) }
        menu.performActionForItem(at: index)
    }

    /// The `NSPopUpButton` drawn at the element's center, if any.
    private static func popUpButton(at target: Located) -> NSPopUpButton? {
        let frame = target.node.frame
        let height = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = NSPoint(x: frame.midX, y: height - frame.midY)
        guard let root = target.window.contentView?.superview ?? target.window.contentView else { return nil }
        let point = target.window.convertPoint(fromScreen: screenPoint)
        var view = root.hitTest(point)
        while let current = view {
            if let popup = current as? NSPopUpButton { return popup }
            view = current.superview
        }
        // SwiftUI may layer views over the control; search for one under the point.
        func search(_ node: NSView) -> NSPopUpButton? {
            if let popup = node as? NSPopUpButton, !popup.isHidden, popup.convert(popup.bounds, to: nil).contains(point) { return popup }
            for child in node.subviews where !child.isHidden { if let found = search(child) { return found } }
            return nil
        }
        return search(root)
    }

    private static func disclose(_ expand: Bool, on target: Located) throws {
        let element = target.node.element
        if target.node.settable(kAXDisclosingAttribute) {
            guard AXUIElementSetAttributeValue(element, kAXDisclosingAttribute as CFString, expand as CFBoolean) == .success else {
                throw Failure(.notReady, "The row rejected the change.", details: ["field": "operation"])
            }
            return
        }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXExpandedAttribute as CFString, &raw) == .success, let expanded = raw as? Bool {
            if expanded != expand, !pressElement(target) { try action(kAXPressAction, on: target) }
            return
        }
        if let now = current(target), target.node.actions.contains("press") {
            if (now != 0) != expand, !pressElement(target) { try action(kAXPressAction, on: target) }
            return
        }
        throw Failure(.notReady, "The element is not a disclosure control or outline row.",
                      details: ["field": "operation", "role": .string(target.role)])
    }
}
