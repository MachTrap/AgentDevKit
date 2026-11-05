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
}

/// Which in-process UI tools an app enables. Each is opt-in.
public struct UIAccess: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let capture = UIAccess(rawValue: 1 << 0)
    public static let tree = UIAccess(rawValue: 1 << 1)
    /// A mutation; read-only sessions never serve it.
    public static let press = UIAccess(rawValue: 1 << 2)
    public static let all: UIAccess = [.capture, .tree, .press]

    public var names: [String] {
        [(UIAccess.capture, "capture"), (.tree, "tree"), (.press, "press")].filter { contains($0.0) }.map(\.1)
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
    public init(windowId: String? = nil, format: String? = nil, maxDimension: Int? = nil, method: String? = nil) {
        self.method = method
        self.windowId = windowId
        self.format = format
        self.maxDimension = maxDimension
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
    public init(windowId: String? = nil, identifierPrefix: String? = nil, onlyIdentified: Bool? = nil, maxDepth: Int? = nil, limit: Int? = nil,
                source: String? = nil) {
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
    public let identifier: String
    public let windowId: String?
    /// Which match to press when several elements share the identifier. Defaults to 0.
    public let index: Int?
    public init(identifier: String, windowId: String? = nil, index: Int? = nil) {
        self.identifier = identifier
        self.windowId = windowId
        self.index = index
    }
}

public struct PressResult: Codable, Sendable {
    public let identifier: String
    public let role: String
    public let revision: UInt64
    public init(identifier: String, role: String, revision: UInt64) {
        self.identifier = identifier
        self.role = role
        self.revision = revision
    }
}
