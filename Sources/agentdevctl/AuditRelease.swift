import AgentDevKitClient
import AgentDevKitCore
import AppKit
import Foundation

/// `agentdevctl audit-release PATH.app`: proves a shipping build contains no AgentDevKit code and publishes no session.
enum AuditRelease {
    static let usage = "agentdevctl audit-release PATH.app [--forbid AgentDevKit,TestingSession] [--no-launch] [--json]"

    struct Finding: Encodable {
        let kind: String
        let file: String
        let architecture: String?
        let detail: String
    }

    struct Report: Encodable {
        let app: String
        let bundleId: String?
        let passed: Bool
        let machO: [String: [String]]
        let signing: [String: String]
        let launchChecked: Bool
        let findings: [Finding]
    }

    /// Mach-O and universal binary magic numbers, in either byte order.
    static let magics: Set<UInt32> = [0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCEFAEDFE, 0xCAFEBABE, 0xBEBAFECA]

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        try? handle.close()
        return magics.contains(data.withUnsafeBytes { $0.load(as: UInt32.self) })
    }

    static func run(_ words: [String], json: Bool) async throws -> Int32 {
        var app: URL?
        var forbidden = ["AgentDevKit", "agentdevkit"]
        var launch = true
        var iterator = words.makeIterator()
        while let word = iterator.next() {
            switch word {
            case "--forbid":
                guard let list = iterator.next() else { throw UsageError(message: "Missing value for --forbid.", usage: usage) }
                forbidden = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "--no-launch": launch = false
            default:
                guard !word.hasPrefix("--"), app == nil else { throw UsageError(message: "Unexpected \(word).", usage: usage) }
                app = URL(filePath: word).standardizedFileURL
            }
        }
        guard let app, FileManager.default.fileExists(atPath: app.path) else { throw UsageError(message: "Pass an existing PATH.app.", usage: usage) }
        var findings: [Finding] = []
        var architectures: [String: [String]] = [:]
        let root = app.path
        func relative(_ url: URL) -> String { String(url.path.dropFirst(root.count).drop(while: { $0 == "/" })) }

        // Embedded code and resources named after a forbidden component.
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var binaries: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let name = relative(url)
            if let term = forbidden.first(where: { url.lastPathComponent.contains($0) }) {
                findings.append(Finding(kind: "embedded", file: name, architecture: nil, detail: "File name contains \(term)."))
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true, values?.isSymbolicLink != true, isMachO(url) { binaries.append(url) }
        }
        for binary in binaries {
            let name = relative(binary)
            let archs = Launch.capture("/usr/bin/lipo", ["-archs", binary.path]).output
                .split(whereSeparator: \.isWhitespace).map(String.init)
            architectures[name] = archs
            for arch in archs.isEmpty ? [""] : archs {
                let archArguments = arch.isEmpty ? [] : ["-arch", arch]
                // Without -a: debugger stab entries hold build paths, which may contain the repository's name.
                let symbols = Launch.capture("/usr/bin/nm", archArguments + ["-j", binary.path])
                var hits: [String: Int] = [:]
                var examples: [String: String] = [:]
                for line in symbols.output.split(separator: "\n") where !line.hasSuffix(": no symbols") && !line.hasPrefix("/") {
                    for term in forbidden where line.contains(term) {
                        hits[term, default: 0] += 1
                        if examples[term] == nil { examples[term] = String(line.prefix(160)) }
                    }
                }
                for (term, count) in hits.sorted(by: { $0.key < $1.key }) {
                    findings.append(Finding(kind: "symbol", file: name, architecture: arch.isEmpty ? nil : arch,
                                            detail: "\(count) symbols contain \(term), such as \(examples[term] ?? "")"))
                }
                let linked = Launch.capture("/usr/bin/otool", archArguments + ["-L", binary.path]).output
                for line in linked.split(separator: "\n").dropFirst() {
                    if let term = forbidden.first(where: { line.contains($0) }) {
                        findings.append(Finding(kind: "linked", file: name, architecture: arch.isEmpty ? nil : arch,
                                                detail: "Links \(line.trimmingCharacters(in: .whitespaces)) (\(term))."))
                    }
                }
            }
        }

        // Signing identity.
        var signing: [String: String] = [:]
        for line in Launch.capture("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]).output.split(separator: "\n") {
            for key in ["Identifier", "Authority", "TeamIdentifier", "Signature", "Format"] where line.hasPrefix(key + "=") {
                signing[key] = (signing[key].map { $0 + "; " } ?? "") + String(line.dropFirst(key.count + 1))
            }
        }

        // Launching with the opt-in flag must publish nothing.
        let bundleId = Bundle(url: app)?.bundleIdentifier
        var launched = false
        if launch, let bundleId {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--enable-agentdevkit", "--allow-agentdevkit-mutations"]
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.addsToRecentItems = false
            if let running = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
                launched = true
                let pid = running.processIdentifier
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    if let session = AgentClient.session(pid: pid, bundleId: bundleId) {
                        findings.append(Finding(kind: "session", file: app.lastPathComponent, architecture: nil,
                                                detail: "Launched with --enable-agentdevkit, PID \(pid) published session \(session.sessionId)."))
                        break
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                running.terminate()
                try? await Task.sleep(for: .milliseconds(500))
                if !running.isTerminated { running.forceTerminate() }
            } else {
                findings.append(Finding(kind: "launch", file: app.lastPathComponent, architecture: nil, detail: "The app could not be launched for the session check."))
            }
        }

        let report = Report(app: app.path, bundleId: bundleId, passed: findings.isEmpty, machO: architectures, signing: signing,
                            launchChecked: launched, findings: findings)
        if json { try printJSON(report) } else {
            print("\(report.passed ? "PASS" : "FAIL")  \(app.lastPathComponent)  \(bundleId ?? "")")
            for (file, archs) in architectures.sorted(by: { $0.key < $1.key }) { print("  Mach-O \(file): \(archs.joined(separator: ", "))") }
            print("  Signing: \(signing["Authority"] ?? signing["Signature"] ?? "unsigned")\(signing["TeamIdentifier"].map { "  team \($0)" } ?? "")")
            let published = findings.contains { $0.kind == "session" }
            print("  Session check: \(launched ? "launched with --enable-agentdevkit; " + (published ? "a session was published" : "no session") : "skipped")")
            for finding in findings { print("  ✗ \(finding.kind) \(finding.file)\(finding.architecture.map { " [\($0)]" } ?? ""): \(finding.detail)") }
        }
        return report.passed ? 0 : 4
    }
}
