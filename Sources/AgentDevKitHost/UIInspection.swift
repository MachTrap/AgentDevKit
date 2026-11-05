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
        let locator: [String: Schema] = [
            "identifier": .string(maxLength: 256), "path": .string(maxLength: 1_024), "role": .string(maxLength: 64),
            "label": .string(maxLength: 256), "index": .integer(minimum: 0, maximum: 100), "windowId": window,
        ]
        let format = Schema.string(maxLength: 8, oneOf: ["png", "jpeg"])
        let mode = Schema.string(maxLength: 16, oneOf: ["active", "window"])
        if access.contains(.capture) {
            commands.append(AppCommand(UICommands.capture, parameters: ObjectSchema([
                "windowId": window, "format": format,
                "maxDimension": .integer(minimum: 64, maximum: 4_096), "method": .string(maxLength: 16, oneOf: ["composite", "display"]),
                "mode": mode, "surfaceId": window, "revision": .integer(minimum: 0),
            ])) { input, _ in
                MenuTracker.start()
                try checkRevision(input.revision, runtime)
                return try capture(input, adapter: adapter, revision: runtime.revision, budget: maxResponseBytes)
            })
            commands.append(AppCommand(UICommands.surfaces, parameters: .empty) { _, _ in
                MenuTracker.start()
                let surfaces = Surfaces.list(secrets: adapter.secretValues())
                return SurfaceList(surfaces: surfaces, truncated: Surfaces.visibleWindows().count > Surfaces.maxSurfaces,
                                   revision: runtime.revision, modalId: NSApp.modalWindow.map(Surfaces.id))
            })
        }
        if access.contains(.tree) {
            commands.append(AppCommand(UICommands.tree, parameters: ObjectSchema([
                "windowId": window, "identifierPrefix": .string(maxLength: 256), "onlyIdentified": .boolean,
                "maxDepth": .integer(minimum: 1, maximum: 60), "limit": .integer(minimum: 1, maximum: Int64(maxElements)),
                "source": .string(maxLength: 16, oneOf: ["accessibility", "appkit", "views"]), "lint": .boolean,
                "revision": .integer(minimum: 0),
            ])) { input, _ in
                try checkRevision(input.revision, runtime)
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
                try checkRevision(input.revision, runtime)
                return try accessibilityTree(input, window: target, secrets: secrets, revision: runtime.revision)
            })
        }
        if access.contains(.capture), access.contains(.tree) {
            commands.append(AppCommand(UICommands.snapshot, parameters: ObjectSchema([
                "windowId": window, "mode": mode, "format": format, "maxDimension": .integer(minimum: 64, maximum: 4_096),
                "identifierPrefix": .string(maxLength: 256), "onlyIdentified": .boolean,
                "limit": .integer(minimum: 1, maximum: Int64(maxElements)),
            ])) { input, _ in
                MenuTracker.start()
                let target = try require(adapter.window(for: input.windowId))
                _ = AccessibilityClient.tree(window: target, request: TreeRequest(limit: 1), secrets: [])
                try? await Task.sleep(for: .milliseconds(40))
                // Everything below runs in one main-actor turn, so the image, tree and revision agree.
                let secrets = adapter.secretValues().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let revision = runtime.revision
                let tree = try accessibilityTree(TreeRequest(windowId: input.windowId, identifierPrefix: input.identifierPrefix,
                                                             onlyIdentified: input.onlyIdentified, limit: input.limit ?? 400),
                                                 window: target, secrets: secrets, revision: revision)
                let treeBytes = (try? JSONEncoder().encode(tree).count) ?? 0
                let surfaces = Surfaces.list(secrets: secrets)
                let capture = try capture(CaptureRequest(windowId: input.windowId, format: input.format, maxDimension: input.maxDimension,
                                                         mode: input.mode),
                                          adapter: adapter, revision: revision, budget: max(65_536, maxResponseBytes - treeBytes - 16_384))
                return UISnapshot(revision: revision, capture: capture, tree: tree, surfaces: surfaces)
            })
        }
        if access.contains(.press) {
            var press = locator
            press["windowId"] = window
            commands.append(AppCommand(UICommands.press, parameters: ObjectSchema(press)) { input, _ in
                let locator = input.locator
                guard !locator.isEmpty else {
                    throw Failure(.invalidParams, "Pass identifier, path, or role and label.", details: ["field": "identifier"])
                }
                let windows = try targets(locator.windowId, adapter: adapter)
                switch try await UIOperations.press(locator, in: windows) {
                case .pressed(let role, let path):
                    // Let the action's state changes land before reporting the revision.
                    try? await Task.sleep(for: .milliseconds(50))
                    var result = PressResult(identifier: locator.identifier ?? path ?? "", role: role, revision: runtime.revision)
                    result.path = path
                    result.evidence = "accessibility"
                    return result
                case .unavailable:
                    guard let identifier = locator.identifier else {
                        throw Failure(.notReady, "The accessibility API is unavailable; only identifier locators work.", details: ["field": "path"])
                    }
                    return try await self.press(PressRequest(identifier: identifier, windowId: locator.windowId, index: locator.index),
                                                window: windows.first, runtime: runtime)
                }
            })
        }
        if access.contains(.perform) {
            var perform = locator
            perform["operation"] = .string(maxLength: 16, oneOf: UIOperations.operations)
            perform["value"] = .value
            perform["item"] = .string(maxLength: 256)
            commands.append(AppCommand(UICommands.perform, parameters: ObjectSchema(perform, required: ["operation"])) { input, _ in
                let windows = try targets(input.windowId, adapter: adapter)
                return try await UIOperations.perform(input, in: windows, runtime: runtime)
            })
        }
        if access.contains(.input) {
            commands.append(AppCommand(UICommands.key, parameters: ObjectSchema([
                "keys": .string(maxLength: 512), "modifiers": .array(.string(maxLength: 16, oneOf: InputSynthesis.modifierNames), maxItems: 4),
                "windowId": window,
            ], required: ["keys"])) { input, _ in
                try await InputSynthesis.keys(input, window: require(adapter.window(for: input.windowId)), runtime: runtime)
            })
            var pointer = locator
            pointer["x"] = .number
            pointer["y"] = .number
            commands.append(AppCommand(UICommands.hover, parameters: ObjectSchema(pointer)) { input, _ in
                let windows = try targets(input.windowId, adapter: adapter)
                return try await InputSynthesis.hover(input, windows: windows, runtime: runtime)
            })
            var scroll = pointer
            scroll["dy"] = .number
            scroll["dx"] = .number
            commands.append(AppCommand(UICommands.scroll, parameters: ObjectSchema(scroll, required: ["dy"])) { input, _ in
                let windows = try targets(input.windowId, adapter: adapter)
                return try await InputSynthesis.scroll(input, windows: windows, runtime: runtime)
            })
        }
        return commands
    }

    static func checkRevision(_ expected: UInt64?, _ runtime: AgentRuntime) throws {
        guard let expected, expected != runtime.revision else { return }
        throw Failure(.staleRevision, "State changed after the expected revision.", retryable: true,
                      details: ["expectedRevision": .integer(Int64(expected)), "latestRevision": .integer(Int64(runtime.revision))])
    }

    /// The windows a locator searches: the named window, or the default window and every surface above it, front first.
    static func targets<Adapter: AgentAdapter>(_ windowId: String?, adapter: Adapter) throws -> [NSWindow] {
        if let windowId, !windowId.isEmpty, windowId != "main" {
            return [try require(adapter.window(for: windowId) ?? Surfaces.resolve(windowId))]
        }
        let base = try require(adapter.window(for: windowId))
        return Surfaces.layers(above: base).reversed() + [base]
    }

    static func accessibilityTree(_ input: TreeRequest, window target: NSWindow, secrets: [String], revision: UInt64) throws -> UITree {
        let size = target.contentView?.bounds.size ?? .zero
        guard let elements = AccessibilityClient.tree(window: target, request: input, secrets: secrets) else {
            return try tree(input, window: target, secrets: secrets, revision: revision)
        }
        var tree = UITree(windowId: target.identifier?.rawValue, title: target.title, size: [Double(size.width), Double(size.height)],
                          elements: elements.list, truncated: elements.truncated, revision: revision)
        if input.lint == true { tree.lint = elements.lint }
        return tree
    }

    // MARK: Windows

    /// With no ID or `main`, the main document window (never an alert or panel while one is visible);
    /// otherwise an exact identifier, `window-<number>`, an identifier prefix, then a title.
    static func defaultWindow(_ windowId: String?) -> NSWindow? { Surfaces.resolve(windowId) }

    static func require(_ window: NSWindow?) throws -> NSWindow {
        guard let window else {
            throw Failure(.notReady, "No visible window matches.", retryable: true, details: ["field": "windowId"])
        }
        return window
    }

    // MARK: Capture

    static func capture<Adapter: AgentAdapter>(_ input: CaptureRequest, adapter: Adapter, revision: UInt64, budget: Int) throws -> WindowCapture {
        if let surfaceId = input.surfaceId {
            guard let surface = Surfaces.resolve(surfaceId) else {
                throw Failure(.notReady, "No visible surface matches.", retryable: true, details: ["field": "surfaceId"])
            }
            var result = try capture(input, window: surface, revision: revision, budget: budget, layers: [])
            result.mode = "surface"
            return result
        }
        let base = try require(adapter.window(for: input.windowId))
        let layers = input.mode == "window" ? [] : Surfaces.layers(above: base)
        var result = try capture(input, window: base, revision: revision, budget: budget, layers: layers)
        result.mode = input.mode ?? "active"
        return result
    }

    /// Renders `window`, then each layer over it in screen position, into one image that covers them all.
    /// With no layers the result matches the v0.5 single-window capture, which also draws an attached sheet.
    static func capture(_ input: CaptureRequest, window: NSWindow?, revision: UInt64, budget: Int, layers: [NSWindow] = []) throws -> WindowCapture {
        let window = try require(window)
        guard let rendered = render(window, method: input.method, drawSheet: layers.isEmpty) else {
            throw Failure(.notReady, "The window has no visible size.", retryable: true)
        }
        var approximations = Set(rendered.approximations)
        var source = rendered.image
        var drawn = [Surfaces.id(window)]
        var pointWidth = window.frame.width
        var origin: [Double]?
        if !layers.isEmpty {
            var parts: [(window: NSWindow, image: NSBitmapImageRep)] = [(window, rendered.image)]
            for layer in layers {
                guard let image = render(layer, method: input.method, drawSheet: false) else { continue }
                approximations.formUnion(image.approximations)
                parts.append((layer, image.image))
                drawn.append(Surfaces.id(layer))
            }
            if parts.count > 1, let combined = compose(parts, base: window) {
                source = combined.image
                pointWidth = combined.bounds.width
                let offset = [Double(window.frame.minX - combined.bounds.minX), Double(combined.bounds.maxY - window.frame.maxY)]
                if offset != [0, 0] { origin = offset }
            } else {
                drawn = [Surfaces.id(window)]
            }
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
                var result = WindowCapture(windowId: window.identifier?.rawValue, title: window.title, width: width, height: height,
                                           scale: Double(width) / pointWidth, format: format, data: data.base64EncodedString(),
                                           bytes: data.count, revision: revision)
                result.surfaces = drawn
                result.approximations = approximations.isEmpty ? nil : approximations.sorted()
                result.appearance = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
                result.locale = Bundle.main.preferredLocalizations.first.map { String($0.prefix(while: { $0 != "-" && $0 != "_" })) }
                result.origin = origin
                return result
            }
            // Too large: try JPEG first, then a smaller image.
            if format == "png" { format = "jpeg" } else { longest *= 0.75 }
        }
        throw Failure(.responseTooLarge, "The capture does not fit the session's response limit.", details: ["field": "maxDimension"])
    }

    /// One window's drawing, at its backing scale. `approximations` names effects drawn approximately.
    static func render(_ window: NSWindow, method: String?, drawSheet: Bool) -> (image: NSBitmapImageRep, approximations: [String])? {
        if Surfaces.kind(window) == .popover, let popover = renderPopover(window, method: method) { return popover }
        // The theme frame includes the title bar and toolbar, not just the content view.
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width >= 1, view.bounds.height >= 1 else { return nil }
        // Open and save panels and some extensions draw in another process; their content is not in this image.
        let remote = containsRemoteView(view) ? ["remoteContent"] : []
        if method == "display" { return displayed(view).map { ($0, remote) } }
        var approximated = false
        guard let image = composited(view, window: window, drawSheet: drawSheet, approximated: &approximated) else { return nil }
        return (image, (approximated ? ["glassEffect"] : []) + remote)
    }

    /// A popover's frame view draws its glass shape mask rather than what a person sees, so draw the content view
    /// over an approximation of the popover background.
    private static func renderPopover(_ window: NSWindow, method: String?) -> (image: NSBitmapImageRep, approximations: [String])? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        var approximated = false
        guard content.bounds.width >= 1, content.bounds.height >= 1,
              let drawn = method == "display" ? displayed(content) : composited(content, window: window, drawSheet: false, approximated: &approximated)
        else { return nil }
        let size = window.frame.size
        let scale = CGFloat(drawn.pixelsWide) / max(1, content.bounds.width)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        let frame = content.convert(content.bounds, to: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        drawn.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return (canvas, ["popoverChrome"] + (approximated ? ["glassEffect"] : []))
    }

    private static func containsRemoteView(_ view: NSView, depth: Int = 0) -> Bool {
        if String(describing: type(of: view)).contains("RemoteView") { return true }
        guard depth < 12 else { return false }
        return view.subviews.contains { containsRemoteView($0, depth: depth + 1) }
    }

    /// Draws each part at its screen position on a canvas covering all of them, at the base window's scale.
    private static func compose(_ parts: [(window: NSWindow, image: NSBitmapImageRep)], base: NSWindow) -> (image: NSBitmapImageRep, bounds: NSRect)? {
        let bounds = parts.reduce(NSRect.null) { $0.union($1.window.frame) }
        let scale = max(1, base.backingScaleFactor)
        guard bounds.width >= 1, bounds.height >= 1,
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for part in parts {
            let frame = NSRect(x: part.window.frame.minX - bounds.minX, y: part.window.frame.minY - bounds.minY,
                               width: part.window.frame.width, height: part.window.frame.height)
            part.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return (canvas, bounds)
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
    private static func composited(_ view: NSView, window: NSWindow, drawSheet: Bool, approximated: inout Bool) -> NSBitmapImageRep? {
        let base: NSBitmapImageRep?
        if #available(macOS 26.0, *) { base = compositedGlass(view, window: window, approximated: &approximated) }
        else { base = displayed(view).flatMap { canvas(like: $0, window: window) } }
        guard let base else { return nil }
        // A sheet is its own window; draw it where it appears over its parent.
        if drawSheet, let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let image = composited(sheetView, window: sheet, drawSheet: true, approximated: &approximated),
           let context = NSGraphicsContext(bitmapImageRep: base) {
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
    private static func compositedGlass(_ view: NSView, window: NSWindow, approximated: inout Bool) -> NSBitmapImageRep? {
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
        if !glass.isEmpty { approximated = true }
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
        return PressResult(identifier: input.identifier ?? "", role: element.role ?? "", revision: runtime.revision)
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
        let lint: [IdentifierLint]
    }

    private static var attributes: [String] { [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute,
                                     kAXTitleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                     kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute,
                                     kAXVisibleRowsAttribute, kAXValueDescriptionAttribute, kAXMinValueAttribute,
                                     kAXMaxValueAttribute, kAXValueIncrementAttribute] }

    struct Node {
        let element: AXUIElement
        let values: [String: CFTypeRef]

        func string(_ name: String) -> String? {
            guard let value = values[name] else { return nil }
            return AccessibilityClient.text(value)
        }
        func number(_ name: String) -> Double? {
            guard let value = values[name], CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return (value as? NSNumber)?.doubleValue
        }
        func bool(_ name: String, _ fallback: Bool) -> Bool { (values[name] as? Bool) ?? fallback }
        var role: String? { string(kAXRoleAttribute) }
        var identifier: String? { string(kAXIdentifierAttribute).flatMap { $0.isEmpty ? nil : $0 } }
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
        var actions: [String] {
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
            return list.map(AccessibilityClient.actionName)
        }
        func settable(_ attribute: String) -> Bool {
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
        }
    }

    /// `AXPress` → `press`, `AXShowMenu` → `showMenu`.
    nonisolated static func actionName(_ raw: String) -> String {
        guard raw.hasPrefix("AX"), raw.count > 2 else { return raw }
        let name = raw.dropFirst(2)
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// A role as a path segment and locator: `AXCheckBox` → `checkbox`.
    nonisolated static func roleName(_ role: String) -> String {
        (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }

    static func read(_ element: AXUIElement) -> Node? {
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

    /// The accessibility element of a window, matched by its frame, then by title. Sheets and popovers may be
    /// children of their parent's element rather than top-level windows. Accessibility frames use a top-left
    /// origin on the primary screen; AppKit frames use a bottom-left origin.
    static func window(_ target: NSWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement], !windows.isEmpty else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? target.frame.maxY
        let expected = CGRect(x: target.frame.minX, y: height - target.frame.maxY, width: target.frame.width, height: target.frame.height)
        func matches(_ frame: CGRect) -> Bool {
            abs(frame.minX - expected.minX) < 2 && abs(frame.minY - expected.minY) < 2 &&
                abs(frame.width - expected.width) < 2 && abs(frame.height - expected.height) < 2
        }
        var titled: AXUIElement?
        for window in windows {
            guard let node = read(window) else { continue }
            if matches(node.frame) { return window }
            if titled == nil, let title = node.string(kAXTitleAttribute), !target.title.isEmpty, title.hasPrefix(target.title) { titled = window }
        }
        let attached = target.isSheet || Surfaces.kind(target) == .popover || target.parent != nil
        if attached {
            // Attached surfaces are reported as AXSheet or AXPopover elements inside their parent window,
            // a popover under the control that shows it. Search breadth first.
            var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
            var visited = 0
            while !queue.isEmpty, visited < 4_000 {
                let (element, depth) = queue.removeFirst()
                visited += 1
                guard let node = read(element) else { continue }
                if depth > 0, let role = node.role, [kAXSheetRole, "AXPopover", kAXWindowRole].contains(role), matches(node.frame) { return element }
                if depth < 12 { queue += node.children.map { ($0, depth + 1) } }
            }
            return nil
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

    /// One visited element with its stable path and nearest identified ancestor.
    struct Visit {
        let node: Node
        let role: String
        let depth: Int
        let path: String
        let containerIdentifier: String?
        let containerPath: String?
    }

    /// Walks the window's elements depth first and computes each one's path: identified ancestors, then the
    /// element's identifier or role, with `[i]` for the i-th sibling of that name under the same ancestor
    /// (`[0]` is omitted). `visit` returns false to skip children. Returns nil when the API is unavailable.
    @discardableResult
    static func walk(window target: NSWindow, maxDepth: Int = 60, visit: (Visit) -> Bool) -> (visited: Int, exhausted: Bool)? {
        guard let window = window(target), let root = read(window) else { return nil }
        var visited = 0
        var exhausted = false
        var stopped = false
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var counts: [String: Int] = [:]
        /// Outlines report the same cells through rows and columns; list each element once.
        func firstVisit(_ element: AXUIElement) -> Bool {
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { return false }
            seen[hash, default: []].append(element)
            return true
        }
        func descend(_ node: Node, depth: Int, prefix: String, container: (identifier: String, path: String)?) {
            for child in node.children where firstVisit(child) {
                guard !stopped else { return }
                visited += 1
                guard visited < 20_000 else { exhausted = true; stopped = true; return }
                guard let childNode = read(child) else { continue }
                guard let role = childNode.role else {
                    if depth < maxDepth { descend(childNode, depth: depth + 1, prefix: prefix, container: container) }
                    continue
                }
                let identifier = childNode.identifier
                let base = identifier ?? roleName(role)
                let key = prefix + "/" + base
                let index = counts[key, default: 0]
                counts[key] = index + 1
                let segment = index == 0 ? base : "\(base)[\(index)]"
                let path = prefix.isEmpty ? segment : prefix + "/" + segment
                let deeper = visit(Visit(node: childNode, role: role, depth: depth, path: path,
                                         containerIdentifier: container?.identifier, containerPath: container?.path))
                if !deeper { if stopped { return } else { continue } }
                if depth < maxDepth {
                    descend(childNode, depth: depth + 1, prefix: identifier != nil ? path : prefix,
                            container: identifier.map { ($0, path) } ?? container)
                }
            }
        }
        descend(root, depth: 0, prefix: "", container: nil)
        return (visited, exhausted)
    }

    /// Treats a missing `[0]` and an explicit one alike, so `row/checkbox` equals `row[0]/checkbox[0]`.
    nonisolated static func normalizedPath(_ path: String) -> String {
        path.split(separator: "/").map { $0.hasSuffix("[0]") ? String($0.dropLast(3)) : String($0) }.joined(separator: "/")
    }

    static func describe(_ visit: Visit, origin: CGPoint, secrets: [String]) -> UIElement {
        func clean(_ text: String?) -> String? {
            guard var text, !text.isEmpty else { return nil }
            for secret in secrets { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
            return text.count > UIInspection.maxValueLength ? String(text.prefix(UIInspection.maxValueLength)) + "…" : text
        }
        let node = visit.node
        let subrole = node.string(kAXSubroleAttribute)
        let secure = subrole == kAXSecureTextFieldSubrole
        let frame = node.frame
        var element = UIElement(
            role: visit.role, subrole: subrole, identifier: node.identifier,
            label: clean(node.string(kAXDescriptionAttribute)) ?? clean(node.string(kAXTitleAttribute)),
            value: secure ? nil : clean(node.string(kAXValueAttribute)),
            frame: [frame.minX - origin.x, frame.minY - origin.y, frame.width, frame.height].map { (Double($0) * 10).rounded() / 10 },
            enabled: node.bool(kAXEnabledAttribute, true), focused: node.bool(kAXFocusedAttribute, false),
            selected: node.bool(kAXSelectedAttribute, false), depth: visit.depth)
        if !secure {
            element.numericValue = node.number(kAXValueAttribute)
            element.valueDescription = clean(node.string(kAXValueDescriptionAttribute))
        }
        element.minValue = node.number(kAXMinValueAttribute)
        element.maxValue = node.number(kAXMaxValueAttribute)
        element.step = node.number(kAXValueIncrementAttribute)
        let actions = node.actions.filter { !$0.isEmpty }
        element.actions = actions.isEmpty ? nil : Array(actions.prefix(12))
        element.path = visit.path
        return element
    }

    static func tree(window target: NSWindow, request: TreeRequest, secrets: [String]) -> Elements? {
        guard let axWindow = window(target), let root = read(axWindow) else { return nil }
        let origin = root.frame.origin
        let limit = request.limit ?? 800
        let maxDepth = request.maxDepth ?? 40
        var list: [UIElement] = []
        var truncated = false
        var byIdentifier: [String: [String]] = [:]
        var copied: [(identifier: String, path: String, container: String)] = []
        var rolesByContainer: [String: Set<String>] = [:]
        let walked = walk(window: target, maxDepth: maxDepth) { visit in
            let identifier = visit.node.identifier
            if request.lint == true, let identifier {
                byIdentifier[identifier, default: []].append(visit.path)
                if visit.containerIdentifier == identifier, let container = visit.containerPath {
                    copied.append((identifier, visit.path, container))
                }
                rolesByContainer[(visit.containerPath ?? "") + "\u{1}" + identifier, default: []].insert(visit.role)
            }
            let keep = (request.onlyIdentified != true || identifier != nil)
                && (request.identifierPrefix.map { identifier?.hasPrefix($0) == true } ?? true)
            if keep {
                if list.count >= limit {
                    truncated = true
                    return request.lint == true
                }
                list.append(describe(visit, origin: origin, secrets: secrets))
            }
            return true
        }
        var lint: [IdentifierLint] = []
        if request.lint == true {
            let copyFix = "SwiftUI copied the container's identifier onto its children. Add .accessibilityElement(children: .contain) to the container, after .accessibilityIdentifier, so each child keeps its own identifier."
            var reported = Set<String>()
            for entry in copied where reported.insert(entry.identifier).inserted && lint.count < 50 {
                let paths = copied.filter { $0.identifier == entry.identifier }.flatMap { [$0.container, $0.path] }
                lint.append(IdentifierLint(kind: .copiedDown, identifier: entry.identifier, paths: Array(NSOrderedSet(array: paths).array.compactMap { $0 as? String }.prefix(8)),
                                           fix: copyFix))
            }
            // A row container that is not an accessibility element passes its identifier to every child,
            // so one identifier lands on elements of different roles under the same identified container.
            for (key, roles) in rolesByContainer.sorted(by: { $0.key < $1.key }) where roles.count > 1 && lint.count < 50 {
                let identifier = String(key.split(separator: "\u{1}").last ?? "")
                guard reported.insert(identifier).inserted else { continue }
                lint.append(IdentifierLint(kind: .copiedDown, identifier: identifier, paths: Array((byIdentifier[identifier] ?? []).prefix(8)),
                                           fix: "\(identifier) is on \(roles.sorted().map(AccessibilityClient.roleName).joined(separator: " and ")) elements in one container: SwiftUI copied a container's identifier, such as a row's, onto each of its children. Add .accessibilityElement(children: .contain) to that container, after .accessibilityIdentifier, so it becomes one element and each child keeps its own identifier."))
            }
            for (identifier, paths) in byIdentifier.sorted(by: { $0.key < $1.key }) where paths.count > 1 && lint.count < 50 {
                lint.append(IdentifierLint(kind: .duplicate, identifier: identifier, paths: Array(paths.prefix(8)),
                                           fix: "Several elements share this identifier. Give each a unique identifier, or target one with --path or --index."))
            }
        }
        return Elements(list: list, truncated: truncated || walked?.exhausted == true, lint: lint)
    }
}
