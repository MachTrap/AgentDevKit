import AgentDevKitClient
import AgentDevKitCore
import AppKit
import Darwin
import Foundation

/// `agentdevctl doctor`: checks each startup stage in order and stops at the first failure with a remedy.
enum Doctor {
    static let usage = "agentdevctl \(globalUsage) doctor [PATH.app | --bundle ID | --pid PID] [--expect-id IDENTIFIER] [--timeout-ms MS] [--json]"

    struct Stage: Encodable {
        let name: String
        var status: String
        var detail: String
        var remedy: String?
        var elapsedMs: Int
    }

    struct Report: Encodable {
        let healthy: Bool
        let stages: [Stage]
        let failedStage: String?
    }

    /// The process's launch arguments, read with `KERN_PROCARGS2`. Works for the user's own processes.
    static func arguments(of pid: Int32) -> [String]? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    static func run(_ words: [String], json: Bool, selector: String?, location: SessionLocation) async throws -> Int32 {
        var words = words
        var selector = selector
        if let index = words.firstIndex(of: "--session"), index + 1 < words.count {
            selector = words[index + 1]
            words.removeSubrange(index...(index + 1))
        }
        var app: URL?
        var bundleId: String?
        var pid: Int32?
        var expect: String?
        var timeoutMs = 5_000
        var iterator = words.makeIterator()
        while let word = iterator.next() {
            switch word {
            case "--bundle": bundleId = iterator.next()
            case "--pid": pid = iterator.next().flatMap(Int32.init)
            case "--expect-id": expect = iterator.next()
            case "--timeout-ms": timeoutMs = iterator.next().flatMap(Int.init) ?? timeoutMs
            default:
                guard !word.hasPrefix("--"), app == nil else { throw UsageError(message: "Unexpected \(word).", usage: usage) }
                app = URL(filePath: word).standardizedFileURL
            }
        }
        var stages: [Stage] = []
        let clock = ContinuousClock()
        func stage(_ name: String, _ body: () async throws -> (detail: String, remedy: String?, ok: Bool?)) async -> Bool {
            let started = clock.now
            var entry = Stage(name: name, status: "ok", detail: "", remedy: nil, elapsedMs: 0)
            do {
                let outcome = try await body()
                entry.detail = outcome.detail
                entry.remedy = outcome.remedy
                entry.status = outcome.ok.map { $0 ? "ok" : "failed" } ?? "skipped"
            } catch let failure as Failure {
                entry.status = "failed"
                entry.detail = "\(failure.code.rawValue): \(failure.message)"
                entry.remedy = failure.details?["remedy"]?.stringValue
            } catch {
                entry.status = "failed"
                entry.detail = "\(error)"
            }
            let elapsed = started.duration(to: clock.now).components
            entry.elapsedMs = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
            stages.append(entry)
            return entry.status != "failed"
        }
        var identity: SessionIdentity?
        var client: AgentClient?
        if selector != nil, app == nil, pid == nil, bundleId == nil {
            if let found = try? AgentClient(session: selector, at: location) {
                identity = found.identity
                client = found
                pid = found.identity.pid
                bundleId = found.identity.bundleId
            } else if let selector, UUID(uuidString: selector) == nil {
                bundleId = selector
            }
        }

        healthy: do {
            // 1. Bundle
            let bundleOK = await stage("bundle") {
                guard let app else { return ("No PATH.app given.", nil, nil) }
                guard FileManager.default.fileExists(atPath: app.path) else {
                    return ("\(app.path) does not exist.", "Build the Testing scheme, or pass the built .app path.", false)
                }
                guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier else {
                    return ("No Info.plist or bundle identifier.", "The build may still be running or failed; check the build log.", false)
                }
                guard let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return ("No executable in the bundle.", "The build may still be running. Wait for it to finish, then run doctor again.", false)
                }
                bundleId = bundleId ?? identifier
                let verify = Launch.capture("/usr/bin/codesign", ["--verify", "--strict", app.path])
                guard verify.status == 0 else {
                    return ("Not validly signed: \(verify.output.trimmingCharacters(in: .whitespacesAndNewlines))",
                            "Sign the app (ad-hoc is fine for local Testing: codesign --force --sign - PATH.app).", false)
                }
                let requirement = Launch.capture("/usr/bin/codesign", ["-d", "-r-", app.path]).output
                    .split(separator: "\n").first { $0.contains("designated") }.map(String.init) ?? "designated requirement unavailable"
                return ("\(identifier)  \(requirement.trimmingCharacters(in: .whitespaces))", nil, true)
            }
            guard bundleOK else { break healthy }
            // 2. Process
            guard await stage("process", {
                if let pid {
                    guard kill(pid, 0) == 0 || errno == EPERM else { return ("PID \(pid) is not running.", "Launch it: agentdevctl launch PATH.app --replace", false) }
                    return ("PID \(pid)", nil, true)
                }
                guard let bundleId else { return ("Nothing to look for.", "Pass PATH.app, --bundle ID, --pid PID or --session.", false) }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
                guard let first = running.last else {
                    return ("\(bundleId) is not running.", "Launch it: agentdevctl launch \(app.map { NameSuggestions.shellQuoted($0.path) } ?? "PATH.app") --replace", false)
                }
                pid = first.processIdentifier
                return ("PID \(first.processIdentifier)\(running.count > 1 ? " (\(running.count) instances; checking the newest)" : "")", nil, true)
            }) else { break healthy }
            // 3. Opt-in flags
            guard await stage("flags", {
                guard let pid, let argv = arguments(of: pid) else { return ("The process arguments could not be read.", nil, nil) }
                guard argv.contains("--enable-agentdevkit") else {
                    return ("Launched without --enable-agentdevkit.", "Relaunch with the opt-in flag: agentdevctl launch PATH.app --replace", false)
                }
                let mutations = argv.contains("--allow-agentdevkit-mutations")
                return ("--enable-agentdevkit\(mutations ? " --allow-agentdevkit-mutations" : " (read-only: add --mutations to launch for fixtures and actions)")", nil, true)
            }) else { break healthy }
            // 4. Bridge registered
            guard await stage("bridge", {
                guard let pid else { return ("No process.", nil, false) }
                if identity == nil {
                    identity = AgentClient.session(pid: pid, bundleId: bundleId)
                        ?? (try? AgentClient.sessions(at: location))?.first { $0.pid == pid }
                }
                guard let identity else {
                    return ("PID \(pid) published no session descriptor.",
                            "Check that this is the Testing build, that it starts AgentSession in applicationDidFinishLaunching, and that its storage opened; look in Console for subsystem dev.agentdevkit.", false)
                }
                guard identity.protocolVersion == Wire.version else {
                    return ("The app speaks \(identity.protocolVersion); these tools speak \(Wire.version).",
                            "Rebuild the app and the tools from the same AgentDevKit release.", false)
                }
                return ("session \(identity.sessionId)  \(identity.protocolVersion)", nil, true)
            }) else { break healthy }
            // 5. Authentication
            guard await stage("authentication", {
                guard let identity else { return ("No session.", nil, false) }
                let found: AgentClient
                if let client { found = client } else {
                    found = try (try? AgentClient(session: identity.sessionId.uuidString, at: location))
                        ?? (try AgentClient(session: identity.bundleId, at: .appContainer(identity.bundleId)))
                }
                client = found
                _ = try await found.hello()
                return ("hello matched \(identity.bundleId)", nil, true)
            }) else { break healthy }
            // 6. Window
            guard await stage("window", {
                guard let client else { return ("No session.", nil, false) }
                let capabilities = try await client.capabilities().result
                guard capabilities?.methods.contains(UICommands.surfaces.method) == true else {
                    return ("The session does not serve ui.surfaces (enable ui: [.capture] in the catalog to check windows).", nil, nil)
                }
                let deadline = clock.now + .milliseconds(timeoutMs)
                repeat {
                    let surfaces = try await client.call(UICommands.surfaces, SurfacesRequest()).result?.surfaces ?? []
                    if let main = surfaces.first(where: \.isDefault) ?? surfaces.first {
                        return ("\(surfaces.count) surfaces; default \(main.kind.rawValue) \(main.id) “\(main.title ?? "")”", nil, true)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                } while clock.now < deadline
                return ("No visible window.", "The app may be stuck before its first window, or showing it off screen. Capture the screen or check the app's startup path.", false)
            }) else { break healthy }
            // 7. Expected element
            _ = await stage("element", {
                guard let expect else { return ("No --expect-id given.", nil, nil) }
                guard let client else { return ("No session.", nil, false) }
                let deadline = clock.now + .milliseconds(timeoutMs)
                var seen: [String] = []
                repeat {
                    let tree = try await client.call(UICommands.tree, TreeRequest(onlyIdentified: true, limit: 3_000)).result
                    seen = tree?.elements.compactMap(\.identifier) ?? []
                    if seen.contains(expect) { return ("#\(expect) is present.", nil, true) }
                    try await Task.sleep(for: .milliseconds(250))
                } while clock.now < deadline
                let closest = NameSuggestions.closest(expect, in: Array(Set(seen)))
                return ("#\(expect) was not found in \(Set(seen).count) identified elements.\(closest.map { " Closest: \($0)." } ?? "")",
                        "Check the identifier, the screen the app opened on, and the system language (launch with --language en).", false)
            })
        }
        let failed = stages.first { $0.status == "failed" }
        let report = Report(healthy: failed == nil, stages: stages, failedStage: failed?.name)
        if json { try printJSON(report) } else {
            for stage in stages {
                let mark = stage.status == "ok" ? "✓" : stage.status == "skipped" ? "–" : "✗"
                print("\(mark) \(stage.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(stage.detail)  (\(stage.elapsedMs) ms)")
                if let remedy = stage.remedy { print("    → \(remedy)") }
            }
        }
        return failed == nil ? 0 : 4
    }
}
