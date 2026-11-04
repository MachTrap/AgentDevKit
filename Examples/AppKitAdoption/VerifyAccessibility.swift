import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func find(_ element: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 16 else { return nil }
    if attribute(element, kAXIdentifierAttribute) as? String == id { return element }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return children.lazy.compactMap { find($0, id: id, depth: depth + 1) }.first
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is required for the verifier.\n".utf8))
    exit(2)
}
let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]) else { exit(2) }
let app = AXUIElementCreateApplication(pid)
let deadline = ContinuousClock.now + .seconds(4)
while ContinuousClock.now < deadline {
    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if args[2] == "press", let button = windows.lazy.compactMap({ find($0, id: args[3]) }).first {
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { exit(3) }
        print("Pressed \(args[3]) through accessibility.")
        exit(0)
    }
    if args[2] == "selected",
       let label = windows.lazy.compactMap({ find($0, id: "documents.selected") }).first,
       attribute(label, kAXValueAttribute) as? String == args[3] {
        print("Visible selection: \(args[3])")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
FileHandle.standardError.write(Data("Accessibility did not observe \(args[2]) \(args[3]).\n".utf8))
exit(4)
