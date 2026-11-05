import AgentDevKitCore
import AppKit
import Carbon.HIToolbox
import Foundation

/// Synthesized in-process input: key events, pointer movement and scroll-wheel events delivered to the app's own
/// windows and handlers. This exercises the app's handlers, such as `onKeyPress` and `onContinuousHover`, but not
/// the system's HID routing, focus traversal across apps, or hit testing by the window server.
@MainActor
enum InputSynthesis {
    nonisolated static let modifierNames = ["cmd", "command", "shift", "option", "alt", "control", "ctrl"]
    static let maxKeys = 64

    private struct Key {
        let code: UInt16
        let characters: String
        let flags: NSEvent.ModifierFlags
    }

    private static func function(_ scalar: Int) -> String { String(Character(UnicodeScalar(UInt16(scalar))!)) }

    private static let named: [String: Key] = {
        var keys: [String: Key] = [
            "return": Key(code: UInt16(kVK_Return), characters: "\r", flags: []),
            "enter": Key(code: UInt16(kVK_ANSI_KeypadEnter), characters: "\u{3}", flags: [.numericPad]),
            "tab": Key(code: UInt16(kVK_Tab), characters: "\t", flags: []),
            "space": Key(code: UInt16(kVK_Space), characters: " ", flags: []),
            "delete": Key(code: UInt16(kVK_Delete), characters: "\u{7f}", flags: []),
            "backspace": Key(code: UInt16(kVK_Delete), characters: "\u{7f}", flags: []),
            "forwarddelete": Key(code: UInt16(kVK_ForwardDelete), characters: function(NSDeleteFunctionKey), flags: [.function]),
            "escape": Key(code: UInt16(kVK_Escape), characters: "\u{1b}", flags: []),
            "esc": Key(code: UInt16(kVK_Escape), characters: "\u{1b}", flags: []),
            "left": Key(code: UInt16(kVK_LeftArrow), characters: function(NSLeftArrowFunctionKey), flags: [.function, .numericPad]),
            "right": Key(code: UInt16(kVK_RightArrow), characters: function(NSRightArrowFunctionKey), flags: [.function, .numericPad]),
            "down": Key(code: UInt16(kVK_DownArrow), characters: function(NSDownArrowFunctionKey), flags: [.function, .numericPad]),
            "up": Key(code: UInt16(kVK_UpArrow), characters: function(NSUpArrowFunctionKey), flags: [.function, .numericPad]),
            "home": Key(code: UInt16(kVK_Home), characters: function(NSHomeFunctionKey), flags: [.function]),
            "end": Key(code: UInt16(kVK_End), characters: function(NSEndFunctionKey), flags: [.function]),
            "pageup": Key(code: UInt16(kVK_PageUp), characters: function(NSPageUpFunctionKey), flags: [.function]),
            "pagedown": Key(code: UInt16(kVK_PageDown), characters: function(NSPageDownFunctionKey), flags: [.function]),
        ]
        let functionCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionCodes.enumerated() {
            keys["f\(index + 1)"] = Key(code: UInt16(code), characters: function(NSF1FunctionKey + index), flags: [.function])
        }
        let printable: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F),
            ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R),
            ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
            ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
        ]
        for (character, code) in printable { keys[String(character)] = Key(code: UInt16(code), characters: String(character), flags: []) }
        return keys
    }()

    private static func modifiers(_ names: [String]) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: throw Failure(.invalidParams, "Unknown modifier.", details: ["field": "modifiers"])
            }
        }
        return flags
    }

    static func keys(_ input: KeyRequest, window: NSWindow, runtime: AgentRuntime) async throws -> InputResult {
        let tokens = input.keys.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, tokens.count <= maxKeys else {
            throw Failure(.invalidParams, "Pass 1…\(maxKeys) space-separated key names.", details: ["field": "keys"])
        }
        let shared = try modifiers(input.modifiers ?? [])
        var keys: [Key] = []
        for token in tokens {
            // `cmd+a` style tokens carry their own modifiers.
            let parts = token.split(separator: "+").map(String.init)
            guard let name = parts.last, let key = named[name.lowercased()] ?? (name.count == 1 ? named[name.lowercased()] : nil) else {
                throw Failure.unknownName(kind: "key", field: "keys", name: token, valid: named.keys.filter { $0.count > 1 }.sorted())
            }
            let flags = try modifiers(parts.dropLast())
            let shifted = name.count == 1 && name != name.lowercased()
            keys.append(Key(code: key.code, characters: shifted ? name : key.characters,
                            flags: key.flags.union(flags).union(shifted ? [.shift] : [])))
        }
        if !window.isKeyWindow { window.makeKey() }
        var delivered = 0
        for key in keys {
            let flags = key.flags.union(shared)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key.characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { continue }
                if type == .keyDown, flags.contains(.command), window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    delivered += 1
                    continue
                }
                if NSApp.isActive, NSApp.keyWindow === window { NSApp.sendEvent(event) } else { window.sendEvent(event) }
                delivered += 1
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        try? await Task.sleep(for: .milliseconds(40))
        return InputResult(events: delivered, revision: runtime.revision)
    }

    // MARK: Pointer

    /// Tracking areas the synthesized pointer is inside, so a later hover elsewhere sends their exit events.
    private static var inside: [ObjectIdentifier: (area: NSTrackingArea, view: NSView)] = [:]

    /// A point in window coordinates (bottom-left origin) and the window it belongs to.
    private static func point(_ locator: ElementLocator, x: Double?, y: Double?, windows: [NSWindow]) throws -> (NSWindow, NSPoint) {
        if let x, let y {
            guard let window = windows.last else { throw UIInspection.notFoundWindow }
            return (window, NSPoint(x: x, y: window.frame.height - y))
        }
        guard !locator.isEmpty else {
            throw Failure(.invalidParams, "Pass an element locator, or x and y.", details: ["field": "identifier"])
        }
        guard let target = try UIOperations.locate(locator, in: windows) else {
            throw Failure(.notReady, "The accessibility API is unavailable in this process.")
        }
        let frame = target.node.frame
        let height = NSScreen.screens.first?.frame.height ?? 0
        return (target.window, target.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: height - frame.midY)))
    }

    private static func topLeft(_ point: NSPoint, in window: NSWindow) -> [Double] {
        [Double(point.x), Double(window.frame.height - point.y)].map { ($0 * 10).rounded() / 10 }
    }

    private static func allViews(_ root: NSView) -> [NSView] {
        var views: [NSView] = []
        func visit(_ view: NSView) {
            guard views.count < 5_000, !view.isHidden else { return }
            views.append(view)
            view.subviews.forEach(visit)
        }
        visit(root)
        return views
    }

    /// AppKit resolves `NSEvent.trackingArea` of an enter or exit event from its tracking number, which for
    /// events the window server generates is the tracking area's address.
    private static func trackingNumber(_ area: NSTrackingArea) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(area).toOpaque())
    }

    static func hover(_ input: HoverRequest, windows: [NSWindow], runtime: AgentRuntime) async throws -> InputResult {
        let (window, location) = try point(input.locator, x: input.x, y: input.y, windows: windows)
        let timestamp = ProcessInfo.processInfo.systemUptime
        var delivered = 0
        var receivers: Set<String> = []
        guard let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw Failure(.internalError, "The pointer event could not be created.") }
        let accepting = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        window.sendEvent(moved)
        delivered += 1
        window.acceptsMouseMovedEvents = accepting
        if let root = window.contentView?.superview ?? window.contentView {
            var current: Set<ObjectIdentifier> = []
            for view in allViews(root) where !view.trackingAreas.isEmpty {
                let local = view.convert(location, from: nil)
                for area in view.trackingAreas {
                    // Views no longer clip to their bounds by default, so the visible rect can extend past them.
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect.intersection(view.bounds) : area.rect
                    guard rect.contains(local), let owner = area.owner as? NSResponder else { continue }
                    let key = ObjectIdentifier(area)
                    current.insert(key)
                    receivers.insert(String(describing: type(of: owner)).components(separatedBy: "<").first ?? "")
                    if inside[key] == nil, area.options.contains(.mouseEnteredAndExited),
                       let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: timestamp,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            trackingNumber: trackingNumber(area), userData: nil) {
                        owner.mouseEntered(with: entered)
                        delivered += 1
                    }
                    inside[key] = (area, view)
                    if area.options.contains(.mouseMoved) {
                        owner.mouseMoved(with: moved)
                        delivered += 1
                    }
                }
            }
            // Leave the areas the pointer was in before.
            for (key, entry) in inside where !current.contains(key) {
                inside[key] = nil
                guard entry.area.options.contains(.mouseEnteredAndExited), let owner = entry.area.owner as? NSResponder,
                      let exited = NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [], timestamp: timestamp,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          trackingNumber: trackingNumber(entry.area), userData: nil) else { continue }
                owner.mouseExited(with: exited)
                delivered += 1
            }
        }
        try? await Task.sleep(for: .milliseconds(60))
        var result = InputResult(events: delivered, point: topLeft(location, in: window), revision: runtime.revision)
        result.receivers = receivers.isEmpty ? nil : receivers.sorted()
        return result
    }

    static func scroll(_ input: ScrollRequest, windows: [NSWindow], runtime: AgentRuntime) async throws -> InputResult {
        let (window, location) = try point(input.locator, x: input.x, y: input.y, windows: windows)
        guard abs(input.dy) <= 10_000, abs(input.dx ?? 0) <= 10_000 else {
            throw Failure(.invalidParams, "Scroll at most 10000 points at a time.", details: ["field": "dy"])
        }
        let screen = window.convertPoint(toScreen: location)
        let height = NSScreen.screens.first?.frame.height ?? 0
        // Positive dy scrolls down the content, as turning the wheel toward you does.
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(-input.dy.rounded()), wheel2: Int32(-(input.dx ?? 0).rounded()), wheel3: 0) else {
            throw Failure(.internalError, "The scroll event could not be created.")
        }
        cgEvent.location = CGPoint(x: screen.x, y: height - screen.y)
        // A discrete wheel event. A continuous (trackpad) event makes NSScrollView run its own tracking loop
        // on the main thread for momentum, which re-enters the main queue while a bridge task runs there.
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        guard let event = NSEvent(cgEvent: cgEvent) else { throw Failure(.internalError, "The scroll event could not be created.") }
        guard let root = window.contentView?.superview ?? window.contentView else { throw UIInspection.notFoundWindow }
        (root.hitTest(location) ?? window.contentView)?.scrollWheel(with: event)
        try? await Task.sleep(for: .milliseconds(60))
        return InputResult(events: 1, point: topLeft(location, in: window), revision: runtime.revision)
    }
}

extension UIInspection {
    static var notFoundWindow: Failure {
        Failure(.notReady, "No visible window matches.", retryable: true, details: ["field": "windowId"])
    }
}
