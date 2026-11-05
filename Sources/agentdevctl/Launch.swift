import AgentDevKitClient
import AgentDevKitCore
import AppKit
import CryptoKit
import Foundation

/// `agentdevctl launch`: optionally builds a Testing scheme, starts the app with the opt-in flags and waits for its session.
enum Launch {
    static let usage = "agentdevctl launch [PATH.app] [--build SCHEME [--project P.xcodeproj | --workspace W.xcworkspace]] [--fresh-profile | --profile UUID] [--fixture ID] [--mutations] [--language en|ru|…] [--arg ARG]… [--replace] [--background] [--wait CONDITION] [--timeout-ms MS] [--json]"

    struct Options {
        var app: URL?
        var scheme: String?
        var project: String?
        var workspace: String?
        var profile: UUID?
        var fixture: String?
        var mutations = false
        var language: String?
        var extra: [String] = []
        var replace = false
        var background = false
        var wait: String?
        var timeoutMs = 20_000
    }

    struct Result: Encodable {
        let sessionId: UUID
        let pid: Int32
        let bundleId: String
        let buildFingerprint: String
        /// The profile UUID passed with --profile, or `fresh`.
        let profile: String
        let app: String
        let arguments: [String]
        let elapsedMs: Int
        let buildLog: String?
        let waited: String?
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next(), !next.isEmpty else { throw UsageError(message: "Missing value for \(flag).", usage: usage) }
            return next
        }
        while let word = iterator.next() {
            switch word {
            case "--build": options.scheme = try value(word)
            case "--project": options.project = try value(word)
            case "--workspace": options.workspace = try value(word)
            case "--fresh-profile": options.profile = nil
            case "--profile":
                guard let profile = UUID(uuidString: try value(word)) else { throw UsageError(message: "--profile takes a UUID.", usage: usage) }
                options.profile = profile
            case "--fixture": options.fixture = try value(word)
            case "--mutations": options.mutations = true
            case "--language": options.language = try value(word)
            case "--arg": options.extra.append(try value(word))
            case "--replace": options.replace = true
            case "--background": options.background = true
            case "--wait": options.wait = try value(word)
            case "--timeout-ms":
                guard let ms = Int(try value(word)), (1_000...600_000).contains(ms) else {
                    throw UsageError(message: "--timeout-ms takes 1000…600000.", usage: usage)
                }
                options.timeoutMs = ms
            default:
                guard !word.hasPrefix("--"), options.app == nil else { throw UsageError(message: "Unexpected \(word).", usage: usage) }
                options.app = URL(filePath: word).standardizedFileURL
            }
        }
        guard options.app != nil || options.scheme != nil else { throw UsageError(message: "Pass PATH.app or --build SCHEME.", usage: usage) }
        if let language = options.language, language.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) == nil {
            throw UsageError(message: "--language takes a language code such as en or pt-BR.", usage: usage)
        }
        return options
    }

    /// The launch arguments the app sees, in order.
    static func arguments(_ options: Options) -> [String] {
        var arguments = ["--enable-agentdevkit"]
        if options.mutations { arguments.append("--allow-agentdevkit-mutations") }
        if let profile = options.profile { arguments += ["--agentdevkit-profile", profile.uuidString] }
        if let fixture = options.fixture { arguments += ["--agentdevkit-fixture", fixture] }
        if let language = options.language {
            arguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language.replacingOccurrences(of: "-", with: "_")]
        }
        return arguments + options.extra
    }

    static func run(_ words: [String], json: Bool, location: SessionLocation) async throws -> Int32 {
        let options = try parse(words)
        let clock = ContinuousClock()
        let started = clock.now
        var app = options.app
        var buildLog: String?
        if let scheme = options.scheme {
            let built = try build(scheme: scheme, project: options.project, workspace: options.workspace, json: json)
            buildLog = built.log
            app = app ?? built.app
        }
        guard let app else { throw Failure(.invalidParams, "No app to launch.") }
        guard let bundle = Bundle(url: app), let bundleId = bundle.bundleIdentifier, bundle.executableURL != nil else {
            throw Failure(.invalidParams, "\(app.path) is not an app bundle with an executable. If it is still building, wait for the build to finish.",
                          details: ["remedy": .string("Run agentdevctl doctor \(NameSuggestions.shellQuoted(app.path)) for details.")])
        }
        if options.replace { await terminate(bundleId: bundleId) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments(options)
        configuration.createsNewApplicationInstance = true
        configuration.activates = !options.background
        configuration.addsToRecentItems = false
        let running: NSRunningApplication
        do { running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration) } catch {
            throw Failure(.sessionNotFound, "The app could not be launched: \(error.localizedDescription)")
        }
        let pid = running.processIdentifier
        let deadline = clock.now + .milliseconds(options.timeoutMs)
        var identity: SessionIdentity?
        while clock.now < deadline {
            if running.isTerminated {
                throw Failure(.sessionExpired, "The app exited during launch.",
                              details: ["remedy": .string("Run agentdevctl doctor \(NameSuggestions.shellQuoted(app.path)) to see which startup stage failed.")])
            }
            if let found = AgentClient.session(pid: pid, bundleId: bundleId) { identity = found; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let identity else {
            throw Failure(.sessionNotFound, "PID \(pid) published no session within \(options.timeoutMs) ms.",
                          details: ["pid": .integer(Int64(pid)),
                                    "remedy": .string("Run agentdevctl doctor --pid \(pid) to see which startup stage failed.")])
        }
        let client = try AgentClient(session: identity.sessionId.uuidString, at: identity.bundleId == bundleId && AgentClient.session(pid: pid) == nil ? .appContainer(bundleId) : location)
        _ = try await client.hello()
        if let condition = options.wait, let wait = AgentOperation.all.first(where: { $0.tool == "wait" }) {
            let remaining = clock.now.duration(to: deadline).components
            let ms = max(1_000, Int(remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000))
            _ = try await wait.run(client, ["until": .string(condition)], timeoutMs: min(AgentOperation.maxWaitMs, ms))
        }
        let elapsed = started.duration(to: clock.now).components
        let result = Result(sessionId: identity.sessionId, pid: pid, bundleId: identity.bundleId, buildFingerprint: identity.buildFingerprint,
                            profile: options.profile?.uuidString ?? "fresh", app: app.path, arguments: arguments(options),
                            elapsedMs: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                            buildLog: buildLog, waited: options.wait)
        if json { try printJSON(result) } else {
            print("\(result.bundleId)  PID \(pid)  session \(identity.sessionId)  \(result.elapsedMs) ms\(options.wait.map { "  \($0)" } ?? "")")
            print("Next: agentdevctl --session \(identity.sessionId) state")
        }
        return 0
    }

    /// Terminates every running instance of the bundle, forcing those still running after five seconds.
    static func terminate(bundleId: String) async {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Builds into a private derived-data folder. Returns the built app and the log path; prints the log tail on failure.
    static func build(scheme: String, project: String?, workspace: String?, json: Bool) throws -> (app: URL, log: String) {
        let container = workspace.map { ["-workspace", $0] } ?? project.map { ["-project", $0] } ?? []
        let key = SHA256.hash(data: Data((FileManager.default.currentDirectoryPath + "|" + (workspace ?? project ?? "") + "|" + scheme).utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let derived = caches.appending(path: "AgentDevKit/DerivedData/\(scheme)-\(key)")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let log = derived.appending(path: "build.log")
        let common = container + ["-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS", "-derivedDataPath", derived.path]
        if !json { FileHandle.standardError.write(Data("Building \(scheme)… (log: \(log.path))\n".utf8)) }
        let status = try runTool("/usr/bin/xcodebuild", common + ["build"], output: log)
        guard status == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n").filter { $0.contains("error:") }.suffix(10).joined(separator: "\n")
            throw Failure(.invalidParams, "The \(scheme) build failed. Log: \(log.path)",
                          details: ["log": .string(log.path), "remedy": .string(tail.isEmpty ? String(text.suffix(2_000)) : tail)])
        }
        let settings = derived.appending(path: "settings.json")
        _ = try runTool("/usr/bin/xcodebuild", common + ["-showBuildSettings", "-json"], output: settings)
        struct Target: Decodable { let buildSettings: [String: String] }
        guard let targets = try? JSONDecoder().decode([Target].self, from: Data(contentsOf: settings)),
              let app = targets.lazy.compactMap({ target -> URL? in
                  guard let directory = target.buildSettings["TARGET_BUILD_DIR"], let name = target.buildSettings["WRAPPER_NAME"] ?? target.buildSettings["FULL_PRODUCT_NAME"],
                        name.hasSuffix(".app") else { return nil }
                  return URL(filePath: directory).appending(path: name)
              }).first else {
            throw Failure(.invalidParams, "The build succeeded, but no .app product was found. Pass PATH.app.", details: ["log": .string(log.path)])
        }
        return (app, log.path)
    }

    static func runTool(_ path: String, _ arguments: [String], output: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a tool and returns its exit status and combined output.
    static func capture(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
