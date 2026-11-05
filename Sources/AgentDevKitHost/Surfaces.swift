import AgentDevKitCore
import AppKit
import CoreGraphics
import Foundation

/// The app's visible window-server surfaces: windows, sheets, popovers, panels, alerts and open menus.
@MainActor
enum Surfaces {
    static let maxSurfaces = 64

    /// The surface ID of a window: its identifier when that is unique among visible windows, else `window-<number>`.
    static func id(_ window: NSWindow) -> String {
        if let identifier = window.identifier?.rawValue, !identifier.isEmpty,
           visibleWindows().filter({ $0.identifier?.rawValue == identifier }).count <= 1 {
            return identifier
        }
        return "window-\(window.windowNumber)"
    }

    static func visibleWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.windowNumber > 0 }
    }

    static func kind(_ window: NSWindow) -> UISurface.Kind {
        let name = String(describing: type(of: window))
        if name.contains("Popover") { return .popover }
        if name.contains("Menu") { return .menu }
        if name.contains("Alert") { return .alert }
        if window.isSheet { return .sheet }
        if window is NSPanel { return .panel }
        return .window
    }

    /// The window a person would call "the app window": the main window, else the largest document window.
    /// An alert, sheet, popover or panel is never chosen while a document window is visible.
    static func defaultBase() -> NSWindow? {
        let windows = visibleWindows().filter { $0.contentView != nil }
        let documents = windows.filter { kind($0) == .window }
        if let main = NSApp.mainWindow, documents.contains(main) { return main }
        if let key = NSApp.keyWindow, documents.contains(key) { return key }
        if let largest = documents.filter(\.canBecomeMain).max(by: { area($0) < area($1) }) ?? documents.max(by: { area($0) < area($1) }) {
            return largest
        }
        return NSApp.keyWindow.flatMap { windows.contains($0) ? $0 : nil } ?? windows.first
    }

    private static func area(_ window: NSWindow) -> CGFloat { window.frame.width * window.frame.height }

    /// `main` or nothing for the default base; then an exact surface ID or identifier, `window-<number>`,
    /// an identifier prefix, and a title.
    static func resolve(_ id: String?) -> NSWindow? {
        guard let id, !id.isEmpty, id != "main" || visibleWindows().contains(where: { $0.identifier?.rawValue == "main" }) else {
            return defaultBase()
        }
        let windows = visibleWindows().filter { $0.contentView != nil }
        if let exact = windows.first(where: { $0.identifier?.rawValue == id }) { return exact }
        if id.hasPrefix("window-"), let number = Int(id.dropFirst(7)), let match = windows.first(where: { $0.windowNumber == number }) {
            return match
        }
        return windows.first { $0.identifier?.rawValue.hasPrefix(id) == true } ?? windows.first { $0.title == id }
    }

    /// The window that owns a surface: its sheet parent or parent window.
    static func owner(_ window: NSWindow) -> NSWindow? { window.sheetParent ?? window.parent }

    static func isOperatorPanel(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(OperatorPrompt.identifierPrefix) == true
    }

    /// Window numbers front to back, from the window server. Needs no permission for the app's own windows.
    static func zOrder() -> [Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = getpid()
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
            return entry[kCGWindowNumber as String] as? Int
        }
    }

    /// Visible windows front to back.
    static func ordered() -> [NSWindow] {
        let order = zOrder()
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return visibleWindows().enumerated().sorted { left, right in
            let l = rank[left.element.windowNumber], r = rank[right.element.windowNumber]
            switch (l, r) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if left.element.level != right.element.level { return left.element.level.rawValue > right.element.level.rawValue }
                return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// Surfaces drawn over `base`, back to front: its sheets, popovers and child windows, recursively, plus
    /// unowned alerts, modal panels and menus in front of it that overlap it. Operator panels are excluded.
    static func layers(above base: NSWindow) -> [NSWindow] {
        let front = ordered()
        let baseIndex = front.firstIndex(of: base) ?? front.count
        func ownedByBase(_ window: NSWindow) -> Bool {
            var current = owner(window)
            var hops = 0
            while let next = current, hops < 8 {
                if next === base { return true }
                current = owner(next)
                hops += 1
            }
            return false
        }
        var result: [NSWindow] = []
        for (index, window) in front.enumerated() where window !== base && !isOperatorPanel(window) && window.contentView != nil {
            let kind = kind(window)
            if ownedByBase(window) {
                result.append(window)
            } else if owner(window) == nil, index < baseIndex || window.level.rawValue > base.level.rawValue,
                      [.alert, .menu, .panel, .popover].contains(kind) || window === NSApp.modalWindow,
                      window.frame.intersects(base.frame) {
                result.append(window)
            }
        }
        // `front` lists front to back; draw back to front.
        return result.reversed()
    }

    static func list(secrets: [String]) -> [UISurface] {
        let base = defaultBase()
        let height = NSScreen.screens.first?.frame.height ?? 0
        var surfaces: [UISurface] = ordered().prefix(maxSurfaces).map { window in
            var title: String? = window.title.isEmpty ? nil : window.title
            for secret in secrets where !secret.isEmpty { title = title?.replacingOccurrences(of: secret, with: "<redacted>") }
            let frame = window.frame
            return UISurface(
                id: id(window), kind: kind(window), parentId: owner(window).map(id),
                frame: [frame.minX, height - frame.maxY, frame.width, frame.height].map { (Double($0) * 10).rounded() / 10 },
                level: window.level.rawValue, title: title.map { ScreenSnapshot.preview($0, maxBytes: 256) },
                key: window.isKeyWindow, main: window.isMainWindow, isDefault: window === base)
        }
        for menu in MenuTracker.shared.open.prefix(8) {
            surfaces.insert(UISurface(id: "menu-\(menu.id)", kind: .menu, parentId: nil, frame: [], level: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                                      title: menu.title.isEmpty ? nil : menu.title, key: false, main: false, isDefault: false,
                                      highlightedItem: menu.highlighted), at: 0)
        }
        return surfaces
    }

    /// A modal panel, sheet, alert or operator question is on screen.
    static func modalSurfaceVisible() -> Bool {
        if NSApp.modalWindow != nil { return true }
        return visibleWindows().contains { window in
            window.isSheet || isOperatorPanel(window) || window is NSSavePanel || [.alert].contains(kind(window))
        }
    }
}

/// Records menus while they track, so `ui.surfaces` can report open menus and their highlighted item.
@MainActor
final class MenuTracker {
    struct OpenMenu {
        let id: Int
        let title: String
        var highlighted: String?
    }

    static let shared = MenuTracker()
    private var menus: [ObjectIdentifier: (menu: NSMenu, id: Int)] = [:]
    private var next = 1
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let began = note.name == NSMenu.didBeginTrackingNotification
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let menu = object as? NSMenu else { return }
                    if began { MenuTracker.shared.began(menu) } else { MenuTracker.shared.ended(menu) }
                }
            })
        }
    }

    /// Starts observing. Called when the host installs its UI commands.
    static func start() { _ = shared }

    private func began(_ menu: NSMenu) {
        menus[ObjectIdentifier(menu)] = (menu, next)
        next += 1
    }

    private func ended(_ menu: NSMenu) { menus[ObjectIdentifier(menu)] = nil }

    /// Menus tracking now, oldest first.
    var openMenus: [NSMenu] { menus.values.sorted { $0.id < $1.id }.map(\.menu) }

    var open: [OpenMenu] {
        menus.values.sorted { $0.id > $1.id }.map { entry in
            OpenMenu(id: entry.id, title: entry.menu.title, highlighted: entry.menu.highlightedItem?.title)
        }
    }
}

extension UIInspection {
    static func modalSurfaceVisible() -> Bool { Surfaces.modalSurfaceVisible() }
}
