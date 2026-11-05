import AgentDevKitClient
import AgentDevKitCore
import Foundation

/// `agentdevctl tcc reset`: wraps `tccutil reset` for a Testing bundle only, and says which grants it cannot reset.
enum TCC {
    static let resetUsage = "agentdevctl tcc reset --bundle BUNDLE_ID [--service All|MediaLibrary|Photos|…] [--json]"

    /// Services kept in the system TCC database. `tccutil` run by the user cannot reset them.
    static let systemServices: [(service: String, pane: String)] = [
        ("SystemPolicyAllFiles", "Full Disk Access"), ("Accessibility", "Accessibility"), ("ScreenCapture", "Screen & System Audio Recording"),
        ("ListenEvent", "Input Monitoring"), ("PostEvent", "Accessibility"), ("DeveloperTool", "Developer Tools"),
        ("SystemPolicyAppBundles", "App Management"), ("Endpoint Security", "Full Disk Access"),
    ]

    struct Report: Encodable {
        let bundleId: String
        let service: String
        let reset: Bool
        let output: String
        let notResettable: [String]
        let remedy: String
    }

    /// A Testing bundle: a `.testing` suffix, or the bundle ID of a live AgentDevKit session (only Testing builds publish one).
    static func isTestingBundle(_ bundleId: String, liveBundles: [String]) -> Bool {
        let lower = bundleId.lowercased()
        return lower.hasSuffix(".testing") || liveBundles.contains(bundleId)
    }

    static func reset(_ arguments: [String], json: Bool, selector: String?, location: SessionLocation) throws -> Int32 {
        var bundleId: String?
        var service = "All"
        var iterator = arguments.makeIterator()
        while let word = iterator.next() {
            switch word {
            case "--bundle": bundleId = iterator.next()
            case "--service": service = iterator.next() ?? ""
            default: throw UsageError(message: "Unexpected \(word).", usage: resetUsage)
            }
        }
        guard let bundleId, !bundleId.isEmpty else { throw UsageError(message: "Pass --bundle.", usage: resetUsage) }
        guard service.range(of: #"^[A-Za-z][A-Za-z ]{0,40}$"#, options: .regularExpression) != nil else {
            throw UsageError(message: "Invalid --service.", usage: resetUsage)
        }
        var live = (try? AgentClient.sessions(at: location).map(\.bundleId)) ?? []
        if let selector, let identity = try? AgentClient(session: selector, at: location).identity { live.append(identity.bundleId) }
        guard isTestingBundle(bundleId, liveBundles: live) else {
            throw Failure(.permissionDenied, "\(bundleId) is not a Testing bundle. tcc reset only targets a bundle ID ending in .testing or one with a live AgentDevKit session.",
                          details: ["remedy": "Launch the Testing build with agentdevctl launch first, or reset a shipping app's grants yourself in System Settings."])
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleId]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let affected = service == "All" ? systemServices : systemServices.filter { $0.service == service }
        let panes = Array(NSOrderedSet(array: affected.map(\.pane)).array.compactMap { $0 as? String })
        let remedy = panes.isEmpty ? "" : "tccutil at user level cannot reset grants in the system database: \(panes.joined(separator: ", ")). Remove the app in System Settings → Privacy & Security → that pane, or switch it off there, then relaunch the app."
        let report = Report(bundleId: bundleId, service: service, reset: process.terminationStatus == 0, output: output,
                            notResettable: affected.map(\.service), remedy: remedy)
        if json { try printJSON(report) } else {
            print(report.reset ? "Reset \(service) for \(bundleId)." : "tccutil failed: \(output)")
            if !output.isEmpty, report.reset { print(output) }
            if !remedy.isEmpty { print(remedy) }
        }
        return report.reset ? 0 : 4
    }
}
