import Foundation

/// In-process views of the app's own windows. They need no Screen Recording or Accessibility
/// permission, because the app inspects itself. They are model-independent but not independent
/// of the app: use XCUITest or an external accessibility client when you need outside evidence.
public enum UICommands {
    /// Renders a window to an image.
    public static let capture = Command<CaptureRequest, WindowCapture>("ui.capture")
    /// Lists accessibility elements of a window.
    public static let tree = Command<TreeRequest, UITree>("ui.tree")
    /// Performs the accessibility press action on an element with a given identifier.
    public static let press = Command<PressRequest, PressResult>("ui.press", mutating: true)
    /// Lists visible windows, sheets, popovers, panels, alerts and open menus.
    public static let surfaces = Command<SurfacesRequest, SurfaceList>("ui.surfaces")
    /// A capture, the accessibility tree and the state revision, all read in one main-actor turn.
    public static let snapshot = Command<UISnapshotRequest, UISnapshot>("ui.snapshot")
    /// Typed accessibility operations on one element: set, choose, expand, collapse, press, increment, decrement.
    public static let perform = Command<PerformRequest, PerformResult>("ui.perform", mutating: true)
    /// Synthesized key events delivered through `NSApp.sendEvent` to the key window.
    public static let key = Command<KeyRequest, InputResult>("ui.key", mutating: true)
    /// Synthesized pointer movement over an element or point, delivered to its window and tracking areas.
    public static let hover = Command<HoverRequest, InputResult>("ui.hover", mutating: true)
    /// A synthesized scroll-wheel event over an element or point.
    public static let scroll = Command<ScrollRequest, InputResult>("ui.scroll", mutating: true)
}

/// Which in-process UI tools an app enables. Each is opt-in.
public struct UIAccess: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Window capture, surfaces and, with `.tree`, `ui.snapshot`.
    public static let capture = UIAccess(rawValue: 1 << 0)
    public static let tree = UIAccess(rawValue: 1 << 1)
    /// A mutation; read-only sessions never serve it.
    public static let press = UIAccess(rawValue: 1 << 2)
    /// Typed accessibility operations (`ui.perform`). A mutation.
    public static let perform = UIAccess(rawValue: 1 << 3)
    /// Synthesized in-process key, hover and scroll events. A mutation.
    public static let input = UIAccess(rawValue: 1 << 4)
    public static let all: UIAccess = [.capture, .tree, .press, .perform, .input]
    /// Everything that changes the app. Read-only sessions drop these.
    public static let mutating: UIAccess = [.press, .perform, .input]

    public var names: [String] {
        [(UIAccess.capture, "capture"), (.tree, "tree"), (.press, "press"), (.perform, "perform"), (.input, "input")]
            .filter { contains($0.0) }.map(\.1)
    }
}

public struct CaptureRequest: Codable, Sendable {
    /// A window identifier, a prefix of one, or a title. Defaults to the key or main window.
    public let windowId: String?
    /// `png` (default) or `jpeg`. The host switches to JPEG when a PNG would not fit the response limit.
    public let format: String?
    /// Longest side of the image in pixels, 64…4096. Defaults to 1600.
    public let maxDimension: Int?
    /// `composite` (default) draws the window and then the content of glass effect views, which AppKit
    /// drawing alone leaves out; `display` uses AppKit drawing only.
    public let method: String?
    /// `active` (default since v0.6): the main document window plus every sheet, popover and alert above it,
    /// composited in z-order. `window`: one window only, as before v0.6.
    public let mode: String?
    /// One surface ID from `ui.surfaces`, captured alone.
    public let surfaceId: String?
    /// Fail with STALE_REVISION unless the journal is still at this revision.
    public let revision: UInt64?
    public init(windowId: String? = nil, format: String? = nil, maxDimension: Int? = nil, method: String? = nil,
                mode: String? = nil, surfaceId: String? = nil, revision: UInt64? = nil) {
        self.method = method
        self.windowId = windowId
        self.format = format
        self.maxDimension = maxDimension
        self.mode = mode
        self.surfaceId = surfaceId
        self.revision = revision
    }
}

public struct WindowCapture: Codable, Sendable {
    public let windowId: String?
    public let title: String?
    public let width: Int
    public let height: Int
    /// Image pixels per window point.
    public let scale: Double
    /// `png` or `jpeg`.
    public let format: String
    /// Base64 image data.
    public let data: String
    public let bytes: Int
    public let revision: UInt64
    /// `active`, `window` or `surface`. Absent before v0.6.
    public var mode: String?
    /// Surface IDs drawn into the image, bottom to top.
    public var surfaces: [String]?
    /// Effects drawn approximately, such as `glassEffect`. Absent when the image is exact AppKit drawing.
    public var approximations: [String]?
    /// `light` or `dark`: the base window's effective appearance.
    public var appearance: String?
    /// The app's preferred localization, such as `en` or `ru`.
    public var locale: String?
    /// The base window's top-left corner in image points, when popovers or alerts extend the image beyond it.
    public var origin: [Double]?

    public init(windowId: String?, title: String?, width: Int, height: Int, scale: Double, format: String, data: String, bytes: Int, revision: UInt64) {
        self.windowId = windowId
        self.title = title
        self.width = width
        self.height = height
        self.scale = scale
        self.format = format
        self.data = data
        self.bytes = bytes
        self.revision = revision
    }

    public var mimeType: String { format == "jpeg" ? "image/jpeg" : "image/png" }
}

public struct TreeRequest: Codable, Sendable {
    public let windowId: String?
    /// Only elements whose identifier starts with this prefix, plus nothing else.
    public let identifierPrefix: String?
    /// Only elements with an accessibility identifier.
    public let onlyIdentified: Bool?
    public let maxDepth: Int?
    public let limit: Int?
    /// `accessibility` (default) asks the system accessibility API, as VoiceOver and XCUITest see the app;
    /// `appkit` walks AppKit accessibility objects directly; `views` lists the AppKit view hierarchy
    /// (class names and frames in `role`, layer class in `subrole`), for diagnosing layout and captures.
    public let source: String?
    /// Report identifiers shared by several elements and identifiers SwiftUI copied from a container onto its children.
    public let lint: Bool?
    /// Fail with STALE_REVISION unless the journal is still at this revision.
    public let revision: UInt64?
    public init(windowId: String? = nil, identifierPrefix: String? = nil, onlyIdentified: Bool? = nil, maxDepth: Int? = nil, limit: Int? = nil,
                source: String? = nil, lint: Bool? = nil, revision: UInt64? = nil) {
        self.lint = lint
        self.revision = revision
        self.source = source
        self.windowId = windowId
        self.identifierPrefix = identifierPrefix
        self.onlyIdentified = onlyIdentified
        self.maxDepth = maxDepth
        self.limit = limit
    }
}

public struct UIElement: Codable, Sendable, Hashable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let label: String?
    /// The element's value as text, truncated and with the app's secret values redacted. Secure fields have none.
    public let value: String?
    /// `[x, y, width, height]` in window points from the top-left corner.
    public let frame: [Double]
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool
    public let depth: Int
    /// The value as a number, for sliders, steppers, checkboxes and progress indicators.
    public var numericValue: Double?
    /// The spoken value, such as "Detailed" for a slider position.
    public var valueDescription: String?
    public var minValue: Double?
    public var maxValue: Double?
    /// The increment of a slider or stepper, when the control reports one.
    public var step: Double?
    /// Accessibility action names without the `AX` prefix, such as `press`, `increment` or `showMenu`.
    public var actions: [String]?
    /// A stable locator: identified ancestors, then this element, with a sibling index where a name repeats,
    /// for example `cleanupQueue/queueRow[3]/checkbox`.
    public var path: String?

    public init(role: String, subrole: String?, identifier: String?, label: String?, value: String?, frame: [Double],
                enabled: Bool, focused: Bool, selected: Bool, depth: Int) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.depth = depth
    }
}

public struct UITree: Codable, Sendable {
    public let windowId: String?
    public let title: String?
    /// Window content size in points.
    public let size: [Double]
    public let elements: [UIElement]
    public let truncated: Bool
    public let revision: UInt64
    /// Identifier problems, when the request asked for `lint`.
    public var lint: [IdentifierLint]?
    public init(windowId: String?, title: String?, size: [Double], elements: [UIElement], truncated: Bool, revision: UInt64) {
        self.windowId = windowId
        self.title = title
        self.size = size
        self.elements = elements
        self.truncated = truncated
        self.revision = revision
    }
}

public struct PressRequest: Codable, Sendable {
    /// Accessibility identifier. Since v0.6 a locator may use `path`, or `role` with `label`, instead.
    public let identifier: String?
    public let windowId: String?
    /// Which match to press when several elements share the identifier. Without it, several matches
    /// fail with AMBIGUOUS_ELEMENT and list their paths.
    public let index: Int?
    /// A `path` from `ui.tree`.
    public let path: String?
    /// A role without the AX prefix, such as `checkbox` or `button`, matched with `label`.
    public let role: String?
    public let label: String?
    public init(identifier: String? = nil, windowId: String? = nil, index: Int? = nil, path: String? = nil,
                role: String? = nil, label: String? = nil) {
        self.identifier = identifier
        self.windowId = windowId
        self.index = index
        self.path = path
        self.role = role
        self.label = label
    }

    public var locator: ElementLocator {
        ElementLocator(identifier: identifier, path: path, role: role, label: label, index: index, windowId: windowId)
    }
}

public struct PressResult: Codable, Sendable {
    public let identifier: String
    public let role: String
    public let revision: UInt64
    public var path: String?
    /// `accessibility`: the control exists, is enabled and responds. It does not prove pointer hit testing.
    public var evidence: String?
    public init(identifier: String, role: String, revision: UInt64) {
        self.identifier = identifier
        self.role = role
        self.revision = revision
    }
}

/// Selects one accessibility element. At least one of `identifier`, `path` or `role`/`label` is required.
public struct ElementLocator: Codable, Sendable, Hashable {
    public var identifier: String?
    public var path: String?
    public var role: String?
    public var label: String?
    public var index: Int?
    public var windowId: String?

    public init(identifier: String? = nil, path: String? = nil, role: String? = nil, label: String? = nil, index: Int? = nil,
                windowId: String? = nil) {
        self.identifier = identifier
        self.path = path
        self.role = role
        self.label = label
        self.index = index
        self.windowId = windowId
    }

    public var isEmpty: Bool { identifier == nil && path == nil && role == nil && label == nil }

    /// A short description for errors and reports.
    public var summary: String {
        [identifier.map { "#\($0)" }, path.map { "path \($0)" }, role.map { "role \($0)" }, label.map { "“\($0)”" },
         index.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " ")
    }
}

public struct IdentifierLint: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The identifier labels more than one element.
        case duplicate
        /// A child carries its container's identifier, usually SwiftUI copying it down.
        case copiedDown
    }
    public let kind: Kind
    public let identifier: String
    public let paths: [String]
    public let fix: String

    public init(kind: Kind, identifier: String, paths: [String], fix: String) {
        self.kind = kind
        self.identifier = identifier
        self.paths = paths
        self.fix = fix
    }
}

// MARK: Surfaces

public struct SurfacesRequest: Codable, Sendable {
    public init() {}
}

/// A window-server surface owned by the app.
public struct UISurface: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case window, sheet, popover, menu, alert, panel }
    /// Pass as `windowId` or `surfaceId`. The window identifier when it has one, else `window-<number>`.
    public let id: String
    public let kind: Kind
    public let parentId: String?
    /// `[x, y, width, height]` in screen points from the top-left of the primary display.
    public let frame: [Double]
    public let level: Int
    public let title: String?
    public let key: Bool
    public let main: Bool
    /// The base window `ui.capture` chooses by default.
    public let isDefault: Bool
    /// For an open menu, the highlighted item's title.
    public let highlightedItem: String?

    public init(id: String, kind: Kind, parentId: String?, frame: [Double], level: Int, title: String?, key: Bool, main: Bool,
                isDefault: Bool, highlightedItem: String? = nil) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.frame = frame
        self.level = level
        self.title = title
        self.key = key
        self.main = main
        self.isDefault = isDefault
        self.highlightedItem = highlightedItem
    }
}

public struct SurfaceList: Codable, Sendable {
    /// Front to back.
    public let surfaces: [UISurface]
    public let truncated: Bool
    public let revision: UInt64
    /// The modal window, when the app runs a modal session.
    public let modalId: String?
    public init(surfaces: [UISurface], truncated: Bool, revision: UInt64, modalId: String?) {
        self.surfaces = surfaces
        self.truncated = truncated
        self.revision = revision
        self.modalId = modalId
    }
}

public struct UISnapshotRequest: Codable, Sendable {
    public let windowId: String?
    public let mode: String?
    public let format: String?
    public let maxDimension: Int?
    public let identifierPrefix: String?
    public let onlyIdentified: Bool?
    public let limit: Int?
    public init(windowId: String? = nil, mode: String? = nil, format: String? = nil, maxDimension: Int? = nil,
                identifierPrefix: String? = nil, onlyIdentified: Bool? = nil, limit: Int? = nil) {
        self.windowId = windowId
        self.mode = mode
        self.format = format
        self.maxDimension = maxDimension
        self.identifierPrefix = identifierPrefix
        self.onlyIdentified = onlyIdentified
        self.limit = limit
    }
}

public struct UISnapshot: Codable, Sendable {
    public let revision: UInt64
    public let capture: WindowCapture
    public let tree: UITree
    public let surfaces: [UISurface]
    public init(revision: UInt64, capture: WindowCapture, tree: UITree, surfaces: [UISurface]) {
        self.revision = revision
        self.capture = capture
        self.tree = tree
        self.surfaces = surfaces
    }
}

// MARK: Typed operations and input

public struct PerformRequest: Codable, Sendable {
    /// `set`, `choose`, `expand`, `collapse`, `press`, `increment` or `decrement`.
    public let operation: String
    public let identifier: String?
    public let path: String?
    public let role: String?
    public let label: String?
    public let index: Int?
    public let windowId: String?
    /// For `set`: a number for sliders and steppers, a string for text, a boolean for checkboxes.
    public let value: JSONValue?
    /// For `choose`: the menu item's title or identifier.
    public let item: String?

    public init(operation: String, locator: ElementLocator, value: JSONValue? = nil, item: String? = nil) {
        self.operation = operation
        identifier = locator.identifier
        path = locator.path
        role = locator.role
        label = locator.label
        index = locator.index
        windowId = locator.windowId
        self.value = value
        self.item = item
    }

    public var locator: ElementLocator {
        ElementLocator(identifier: identifier, path: path, role: role, label: label, index: index, windowId: windowId)
    }
}

public struct PerformResult: Codable, Sendable {
    public let operation: String
    public let role: String
    public let path: String?
    /// The element's value after the operation, as text.
    public let value: String?
    public let numericValue: Double?
    public let revision: UInt64
    /// Always `accessibility`: proves the control exists, is enabled and responds, not pointer hit testing.
    public let evidence: String

    public init(operation: String, role: String, path: String?, value: String?, numericValue: Double?, revision: UInt64) {
        self.operation = operation
        self.role = role
        self.path = path
        self.value = value
        self.numericValue = numericValue
        self.revision = revision
        evidence = "accessibility"
    }
}

public struct KeyRequest: Codable, Sendable {
    /// Space-separated key names: `Down Down Return`, `Tab`, `Escape`, `a`, `F5`.
    public let keys: String
    /// `cmd`, `shift`, `option`, `control`, applied to every key.
    public let modifiers: [String]?
    public let windowId: String?
    public init(keys: String, modifiers: [String]? = nil, windowId: String? = nil) {
        self.keys = keys
        self.modifiers = modifiers
        self.windowId = windowId
    }
}

public struct HoverRequest: Codable, Sendable {
    public let identifier: String?
    public let path: String?
    public let role: String?
    public let label: String?
    public let index: Int?
    public let windowId: String?
    /// A point in window points from the top-left, instead of an element.
    public let x: Double?
    public let y: Double?
    public init(locator: ElementLocator = ElementLocator(), x: Double? = nil, y: Double? = nil) {
        identifier = locator.identifier
        path = locator.path
        role = locator.role
        label = locator.label
        index = locator.index
        windowId = locator.windowId
        self.x = x
        self.y = y
    }
    public var locator: ElementLocator {
        ElementLocator(identifier: identifier, path: path, role: role, label: label, index: index, windowId: windowId)
    }
}

public struct ScrollRequest: Codable, Sendable {
    public let identifier: String?
    public let path: String?
    public let role: String?
    public let label: String?
    public let index: Int?
    public let windowId: String?
    public let x: Double?
    public let y: Double?
    /// Points to scroll down the content; negative scrolls up.
    public let dy: Double
    public let dx: Double?
    public init(locator: ElementLocator = ElementLocator(), x: Double? = nil, y: Double? = nil, dy: Double, dx: Double? = nil) {
        identifier = locator.identifier
        path = locator.path
        role = locator.role
        label = locator.label
        index = locator.index
        windowId = locator.windowId
        self.x = x
        self.y = y
        self.dy = dy
        self.dx = dx
    }
    public var locator: ElementLocator {
        ElementLocator(identifier: identifier, path: path, role: role, label: label, index: index, windowId: windowId)
    }
}

public struct InputResult: Codable, Sendable {
    /// Events delivered.
    public let events: Int
    /// The point used, in window points from the top-left, for pointer input.
    public let point: [Double]?
    public let revision: UInt64
    /// `in-process`: the app's own handlers ran; the system's HID routing was not exercised.
    public let evidence: String
    /// For pointer input: the classes of the views whose tracking areas received events.
    public var receivers: [String]?
    public init(events: Int, point: [Double]? = nil, revision: UInt64) {
        self.events = events
        self.point = point
        self.revision = revision
        evidence = "in-process"
    }
}
