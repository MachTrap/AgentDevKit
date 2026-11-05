import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation

/// `agentdevctl recipe run FILE` and `agentdevctl recipe record start|stop`.
enum Recipes {
    static let runUsage = "agentdevctl \(globalUsage) recipe run FILE [--repeat N] [--out DIR] [--json]"
    static let recordUsage = "agentdevctl recipe record start [--file DRAFT.json] | stop | status"

    static func run(_ arguments: [String], json: Bool, client: AgentClient) async throws -> Int32 {
        var file: String?
        var repeatCount: Int?
        var output = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".agentdevkit/recipe-failures")
        var iterator = arguments.makeIterator()
        while let word = iterator.next() {
            switch word {
            case "--repeat":
                guard let text = iterator.next(), let value = Int(text), (1...1_000).contains(value) else {
                    throw UsageError(message: "--repeat takes 1…1000.", usage: runUsage)
                }
                repeatCount = value
            case "--out":
                guard let text = iterator.next() else { throw UsageError(message: "Missing value for --out.", usage: runUsage) }
                output = URL(filePath: text)
            default:
                guard file == nil, !word.hasPrefix("--") else { throw UsageError(message: "Unexpected \(word).", usage: runUsage) }
                file = word
            }
        }
        guard let file else { throw UsageError(message: "Pass a recipe file.", usage: runUsage) }
        let recipe: Recipe
        do {
            recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: URL(filePath: file)))
        } catch let error as DecodingError {
            throw Failure(.invalidParams, "\(file) is not a valid recipe: \(describe(error))")
        } catch {
            throw Failure(.invalidParams, "\(file) could not be read.")
        }
        var named = recipe
        if named.name == nil { named.name = URL(filePath: file).deletingPathExtension().lastPathComponent }
        let runner = RecipeRunner(client: client, output: output) { line in
            if !json { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        }
        let report = await runner.run(named, repeat: repeatCount)
        if json {
            try printJSON(report)
        } else {
            print(report.passed ? "PASS  \(report.name)  \(report.rounds) rounds, \(report.stepsRun) steps, \(report.durationMs) ms"
                                : "FAIL  \(report.name)  after \(report.rounds) passing rounds")
            for burst in report.bursts.prefix(3) {
                print("  burst \(burst.step) round \(burst.round): \(burst.steps) steps, gaps \(burst.gapsMs.map { String(format: "%.2f", $0) }.joined(separator: ", ")) ms, revision \(burst.revisionBefore.map(String.init) ?? "?") → \(burst.revisionAfter.map(String.init) ?? "?")")
            }
            for answer in report.answers { print("  answer \(answer)") }
            for note in report.notes { print("  note \(note)") }
            if let failure = report.failure {
                print("  round \(failure.round), step \(failure.step) (\(failure.kind)): \(failure.message)")
                if let expected = failure.expected { print("    expected \(NameSuggestions.compactJSON(expected))") }
                if let observed = failure.observed { print("    observed \(NameSuggestions.compactJSON(observed))") }
                if let revision = failure.revision { print("    revision \(revision)") }
                if let snapshot = failure.snapshot { print("    snapshot \(snapshot)") }
            }
        }
        return report.passed ? 0 : 4
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context): "missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            "\(context.codingPath.map(\.stringValue).joined(separator: ".")) \(context.debugDescription)"
        @unknown default: "invalid"
        }
    }

    static func record(_ arguments: [String], json: Bool) throws -> Int32 {
        switch arguments.first {
        case "start":
            var file = "recipe-draft.json"
            if arguments.count == 3, arguments[1] == "--file" { file = arguments[2] } else if arguments.count != 1 {
                throw UsageError(message: "Unexpected arguments.", usage: recordUsage)
            }
            let draft = URL(filePath: file).standardizedFileURL
            try Recording.start(draft: draft)
            print("Recording to \(draft.path). Run commands as usual, then: agentdevctl recipe record stop")
        case "stop":
            guard let (draft, recipe) = try Recording.stop() else {
                printError("No recording is in progress.")
                return 4
            }
            if json { try printJSON(recipe) } else { print("Wrote \(recipe.steps.count) steps to \(draft.path)") }
        case "status":
            print(Recording.active.map { "Recording to \($0.path)" } ?? "Not recording.")
        default:
            throw UsageError(message: "Choose start, stop or status.", usage: recordUsage)
        }
        return 0
    }
}

/// Records the commands an agent runs into a draft recipe, while `recipe record start` is in effect.
/// State lives in a per-user temporary file, so it spans separate `agentdevctl` invocations.
enum Recording {
    private static var stateFile: URL {
        FileManager.default.temporaryDirectory.appending(path: "agentdevkit-recording-\(getuid()).json")
    }

    private struct State: Codable {
        var draft: String
        var steps: [JSONValue]
        var fixture: String?
        var route: String?
        var context: [String: JSONValue]?
    }

    static var active: URL? {
        (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }.map { URL(filePath: $0.draft) }
    }

    static func start(draft: URL) throws {
        let data = try JSONEncoder().encode(State(draft: draft.path, steps: []))
        try data.write(to: stateFile, options: .atomic)
        chmod(stateFile.path, 0o600)
    }

    static func stop() throws -> (URL, Recipe)? {
        guard let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        var recipe = Recipe(name: URL(filePath: state.draft).deletingPathExtension().lastPathComponent, fixture: state.fixture,
                            route: state.route, steps: state.steps)
        recipe.context = state.context
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(recipe).write(to: URL(filePath: state.draft), options: .atomic)
        try? FileManager.default.removeItem(at: stateFile)
        return (URL(filePath: state.draft), recipe)
    }

    /// Appends the step for a successful command. Reads are recorded only as `--field` assertions.
    static func append(operation: AgentOperation, values: [String: JSONValue], fixed: [String: JSONValue],
                       observedField: (String, JSONValue)? = nil) {
        guard let data = try? Data(contentsOf: stateFile), var state = try? JSONDecoder().decode(State.self, from: data) else { return }
        func locator() -> [String: JSONValue] {
            var result: [String: JSONValue] = [:]
            for (field, key) in [("identifier", "id"), ("path", "path"), ("role", "role"), ("label", "label"), ("index", "index"), ("windowId", "window")] {
                if let value = values[field] { result[key] = value }
            }
            return result
        }
        var step: [String: JSONValue]?
        switch operation.tool {
        case "prepare" where state.fixture == nil && state.steps.isEmpty:
            state.fixture = values["fixture"]?.stringValue
            state.route = values["route"]?.stringValue
            state.context = values["context"]?.objectValue
        case "prepare", "fixtures":
            step = ["fixture": values["fixture"] ?? ""]
            if let routeStep = values["route"] { state.steps.append(.object(step!)); step = ["navigate": routeStep] }
        case "navigate":
            step = ["navigate": values["route"] ?? ""]
            if let context = values["context"] { step?["context"] = context }
        case "invoke":
            step = ["action": values["actionId"] ?? "", "args": values["arguments"] ?? [:]]
        case "ui_perform":
            step = locator().merging(["perform": values["operation"] ?? fixed["operation"] ?? ""]) { a, _ in a }
            if let value = values["value"] { step?["value"] = value }
            if let item = values["item"] { step?["item"] = item }
        case "press":
            step = ["press": .object(locator())]
        case "ui_key":
            step = ["key": values["keys"] ?? ""]
        case "ui_hover":
            step = ["hover": .object(locator())]
        case "ui_scroll":
            step = ["scroll": .object(locator()), "dy": values["dy"] ?? 0]
        case "wait":
            if let until = values["until"] { step = ["wait": until] }
            else if values["condition"]?.stringValue == "state.field_equals", let field = values["arguments.field"]?.stringValue {
                step = ["wait": .string("\(field)=\(NameSuggestions.compactJSON(values["arguments.value"] ?? .null))")]
            } else if let condition = values["condition"] { step = ["wait": condition] }
        case "state", "observe":
            if let (field, value) = observedField { step = ["assert": ["field": .string(field), "equals": value]] }
        default:
            break
        }
        if let step { state.steps.append(.object(step)) }
        if let encoded = try? JSONEncoder().encode(state) { try? encoded.write(to: stateFile, options: .atomic) }
    }
}

/// `agentdevctl invariants --watch`: prints each change to the invariant report until interrupted or the timeout.
enum Watch {
    static func invariants(_ arguments: [String], json: Bool, client: AgentClient) async throws -> Int32 {
        var timeoutMs = 600_000
        if let index = arguments.firstIndex(of: "--timeout-ms"), index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
            timeoutMs = value
        }
        guard let list = AgentOperation.all.first(where: { $0.tool == "invariants" }) else { return 2 }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        var last = ""
        while ContinuousClock.now < deadline {
            let response = try await list.run(client, [:])
            let result = response.objectValue?["result"] ?? .null
            let invariants = result.objectValue?["invariants"] ?? .null
            let line = json ? NameSuggestions.compactJSON(result) : list.render(result)
            let key = NameSuggestions.compactJSON(invariants)
            if key != last {
                last = key
                if !json { print("— revision \(result.objectValue?["revision"]?.integerValue ?? 0)") }
                print(line)
                fflush(stdout)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return 0
    }
}
