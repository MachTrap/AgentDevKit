import AgentDevKitClient
import AgentDevKitCore
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// The opt-in desktop runner. It drives real pointer and keyboard input through CGEvent, so it needs an
// Accessibility grant, and it only ever acts on the selected session's process. It is never linked into apps.

let usage = """
Usage: agentdevkit-desktop [--session ID_OR_BUNDLE] COMMAND [options] [--json]
  check                                   Report whether this runner has the Accessibility grant.
  click (--id ID | --path PATH | --x X --y Y) [--window W] [--pid PID]
  drag  (--from-id ID | --from-path PATH | --from X,Y) (--to-id ID | --to-path PATH | --to X,Y) [--steps 20] [--hold-ms 150] [--window W] [--pid PID]
  key   --keys "Tab Tab Return" [--modifiers cmd,shift] [--pid PID]
Points are window points from the window's top-left. Evidence is labelled "desktop": the system routed real events.
Every command refuses a --pid other than the session's, and pointer input over another process's window.
"""

struct Report: Encodable {
    let evidence = "desktop"
    let command: String
    let pid: Int32
    let points: [[Double]]
    let events: Int
    let revision: UInt64?
}

func fail(_ code: Failure.Code, _ message: String, remedy: String? = nil) -> Failure {
    Failure(code, message, details: remedy.map { ["remedy": .string($0)] })
}

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
var selector: String?
var location: SessionLocation = .local
while let first = arguments.first, ["--session", "--container", "--app-group", "--pairing-dir"].contains(first), arguments.count >= 2 {
    switch first {
    case "--session": selector = arguments[1]
    case "--container": location = .appContainer(arguments[1])
    case "--app-group": location = .appGroup(arguments[1])
    default: location = .pairingDirectory(URL(fileURLWithPath: arguments[1], isDirectory: true))
    }
    arguments.removeFirst(2)
}
if selector == nil { selector = (try? SessionDefaults.resolve(explicit: nil))?.selector }

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
}

/// Front-to-back on-screen windows: owner PID and bounds in global top-left coordinates.
nonisolated func windowOwner(at point: CGPoint) -> Int32? {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for entry in info {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Double],
              let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        if rect.contains(point) { return entry[kCGWindowOwnerPID as String] as? Int32 }
    }
    return nil
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func flags(_ list: String?) throws -> CGEventFlags {
    var result: CGEventFlags = []
    for name in (list ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
        switch name {
        case "cmd", "command": result.insert(.maskCommand)
        case "shift": result.insert(.maskShift)
        case "option", "alt": result.insert(.maskAlternate)
        case "control", "ctrl": result.insert(.maskControl)
        default: throw fail(.invalidParams, "Unknown modifier \(name).")
        }
    }
    return result
}

do {
    guard let command = arguments.first, ["check", "click", "drag", "key", "help"].contains(command) else {
        print(usage)
        exit(arguments.isEmpty ? 0 : 2)
    }
    if command == "help" { print(usage); exit(0) }
    let trusted = AXIsProcessTrusted()
    if command == "check" {
        struct Check: Encodable { let trusted: Bool; let runner: String; let remedy: String? }
        let check = Check(trusted: trusted, runner: CommandLine.arguments[0],
                          remedy: trusted ? nil : "System Settings → Privacy & Security → Accessibility: allow the app that runs agentdevkit-desktop (your terminal), then retry.")
        if json { printJSON(check) } else { print(trusted ? "Accessibility granted." : "Accessibility not granted. \(check.remedy!)") }
        exit(trusted ? 0 : 4)
    }
    let client = try AgentClient(session: selector, at: location)
    let pid = client.identity.pid
    if let requested = option("--pid").flatMap(Int32.init), requested != pid {
        throw fail(.permissionDenied, "PID \(requested) is not the session's process (\(pid)). The desktop runner acts only on the selected session.")
    }
    guard trusted else {
        throw fail(.permissionDenied, "agentdevkit-desktop has no Accessibility grant, so it cannot post input events.",
                   remedy: "System Settings → Privacy & Security → Accessibility: allow your terminal app, then retry. Check with: agentdevctl desktop check")
    }
    let windowId = option("--window")

    /// The screen point (global, top-left origin) for an element ID, path, or window point.
    func point(id: String?, path: String?, xy: String?) async throws -> CGPoint {
        let surfaces = try await client.call(UICommands.surfaces, SurfacesRequest()).result?.surfaces ?? []
        guard let window = windowId.flatMap({ wanted in surfaces.first { $0.id == wanted || $0.title == wanted } })
                ?? surfaces.first(where: \.isDefault) ?? surfaces.first, window.frame.count == 4 else {
            throw fail(.notReady, "No visible window in the session.")
        }
        if let xy {
            let parts = xy.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { throw fail(.invalidParams, "Points are X,Y.") }
            return CGPoint(x: window.frame[0] + parts[0], y: window.frame[1] + parts[1])
        }
        let tree = try await client.call(UICommands.tree, TreeRequest(windowId: windowId ?? window.id, limit: 3_000)).result
        let matches = tree?.elements.filter { element in
            (id == nil || element.identifier == id) && (path == nil || element.path == path)
        } ?? []
        guard matches.count == 1, let element = matches.first, element.frame.count == 4 else {
            throw fail(matches.isEmpty ? .notReady : .ambiguousElement,
                       matches.isEmpty ? "No element matches." : "\(matches.count) elements match; pass --path.")
        }
        return CGPoint(x: window.frame[0] + element.frame[0] + element.frame[2] / 2, y: window.frame[1] + element.frame[1] + element.frame[3] / 2)
    }

    func owned(_ point: CGPoint) throws {
        guard windowOwner(at: point) == pid else {
            throw fail(.permissionDenied, "The point \(Int(point.x)),\(Int(point.y)) is covered by another process's window. The runner only acts on PID \(pid).",
                       remedy: "Bring the app's window to the front and keep the point inside it.")
        }
    }

    func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    var points: [CGPoint] = []
    var events = 0
    switch command {
    case "click":
        let target = try await point(id: option("--id"), path: option("--path"), xy: option("--x").flatMap { x in option("--y").map { "\(x),\($0)" } })
        try owned(target)
        post(.mouseMoved, at: target)
        try await Task.sleep(for: .milliseconds(30))
        post(.leftMouseDown, at: target)
        try await Task.sleep(for: .milliseconds(40))
        post(.leftMouseUp, at: target)
        points = [target]
        events = 3
    case "drag":
        let from = try await point(id: option("--from-id"), path: option("--from-path"), xy: option("--from"))
        let to = try await point(id: option("--to-id"), path: option("--to-path"), xy: option("--to"))
        try owned(from)
        try owned(to)
        let steps = max(2, min(200, option("--steps").flatMap(Int.init) ?? 20))
        let hold = max(0, min(5_000, option("--hold-ms").flatMap(Int.init) ?? 150))
        post(.mouseMoved, at: from)
        try await Task.sleep(for: .milliseconds(30))
        post(.leftMouseDown, at: from)
        try await Task.sleep(for: .milliseconds(hold))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            try await Task.sleep(for: .milliseconds(12))
        }
        try await Task.sleep(for: .milliseconds(hold))
        post(.leftMouseUp, at: to)
        points = [from, to]
        events = steps + 3
    case "key":
        guard let keys = option("--keys") else { throw fail(.invalidParams, "Pass --keys.") }
        let shared = try flags(option("--modifiers"))
        for token in keys.split(whereSeparator: \.isWhitespace) {
            guard let code = keyCodes[token.lowercased()] else { throw fail(.invalidParams, "Unknown key \(token).") }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
                event.flags = shared
                event.postToPid(pid)
                events += 1
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    default:
        break
    }
    try await Task.sleep(for: .milliseconds(120))
    let revision = try? await client.call(AppCommands.snapshot, SnapshotRequest(scope: "current-screen")).result?.revision
    let report = Report(command: command, pid: pid, points: points.map { [Double($0.x), Double($0.y)] }, events: events, revision: revision)
    if json { printJSON(report) } else {
        print("\(command): \(events) events to PID \(pid)\(points.isEmpty ? "" : " at " + points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " → "))  revision \(revision.map(String.init) ?? "?")  evidence desktop")
    }
} catch {
    let failure = error as? Failure ?? Failure(.internalError, "\(error)")
    if json { printJSON(Response<EmptyParameters>(error: failure)) } else {
        FileHandle.standardError.write(Data("\(failure.code.rawValue)  \(failure.message)\n".utf8))
        if let remedy = failure.details?["remedy"]?.stringValue { FileHandle.standardError.write(Data("\(remedy)\n".utf8)) }
    }
    exit(failure.code.exitCode)
}
