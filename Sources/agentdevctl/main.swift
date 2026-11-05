import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation

let globalUsage = "[--session ID_OR_BUNDLE]"

func usage(for operation: AgentOperation, command: [String]? = nil, fixed: [String: JSONValue] = [:]) -> String {
    let options = operation.fields.compactMap { field -> String? in
        guard let flag = field.flag, fixed[field.name] == nil else { return nil }
        let option: String
        if field.kind == .boolean {
            option = field.negativeFlag.map { "\(flag) | \($0)" } ?? flag
        } else {
            option = "\(flag) \(field.path.last!.uppercased())"
        }
        return field.required && field.defaultValue == nil ? option : "[\(option)]"
    }
    let output = operation.image ? ["[--out FILE]"] : []
    return "agentdevctl \(globalUsage) " + ((command ?? operation.command) + options + output + ["[--timeout-ms MS]", "[--json]"]).joined(separator: " ")
}

let usage: String = {
    var lines = [
        "Usage:",
        "  agentdevctl --version",
        "  agentdevctl help COMMAND   (one command's options)",
        "  " + Scaffold.usage + "   (write a Testing target's files and print the Xcode steps)",
        "  Global options (before the command): --session ID_OR_BUNDLE · --app-group ID | --pairing-dir PATH | --container BUNDLE_ID",
        "  Without --session: $AGENTDEVKIT_SESSION, then the nearest .agentdevkit.json ({\"session\": \"BUNDLE_ID\"}).",
        "  A bundle ID passed to --session also finds a sandboxed app's session in its own container.",
        "  agentdevctl session list [--json]",
        "  agentdevctl \(globalUsage) session ping [--json]",
        "  agentdevctl \(globalUsage) capabilities [--json]",
        "  " + Launch.usage,
        "  " + Doctor.usage,
        "  " + AuditRelease.usage,
        "  " + Recipes.runUsage,
        "  " + Recipes.recordUsage,
        "  " + TCC.resetUsage,
        "  agentdevctl \(globalUsage) invariants [--watch] [--json]",
        "  agentdevctl \(globalUsage) desktop COMMAND …   (opt-in runner for real pointer and keyboard input; see agentdevctl desktop help)",
    ]
    for operation in AgentOperation.all {
        lines.append("  " + usage(for: operation))
        for alias in operation.aliases { lines.append("  " + usage(for: operation, command: alias.command, fixed: alias.fixed)) }
    }
    lines.append("Exit codes: 0 ok · 2 invalid input · 3 session or connection · 4 app failure or failed check · 5 timeout · 6 version or identity mismatch")
    return lines.joined(separator: "\n")
}()

/// A usage error that prints only the failing command's usage.
struct UsageError: Error {
    let message: String
    let usage: String
}

let globalOptions = ["--session", "--app-group", "--pairing-dir", "--container"]

/// Accepts `--option=value`, and a global option and its value passed as one word, as zsh does with
/// `S="--session com.example.app"; agentdevctl $S state`.
func normalize(_ raw: [String]) -> [String] {
    raw.flatMap { argument -> [String] in
        guard argument.hasPrefix("--") else { return [argument] }
        if let equals = argument.firstIndex(of: "="), !argument[..<equals].contains(" ") {
            return [String(argument[..<equals]), String(argument[argument.index(after: equals)...])]
        }
        if let option = globalOptions.first(where: { argument.hasPrefix($0 + " ") }) {
            return [option, argument.dropFirst(option.count).trimmingCharacters(in: .whitespaces)]
        }
        return [argument]
    }
}

var arguments = normalize(Array(CommandLine.arguments.dropFirst()))
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
}

do {
    var explicit: String?
    var location: SessionLocation = .local
    var locationSet = false
    while let option = arguments.first, globalOptions.contains(option) {
        guard arguments.count >= 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else {
            throw Failure(.invalidParams, "Missing value for \(option).")
        }
        let value = arguments[1]
        if option == "--session" {
            guard explicit == nil else { throw Failure(.invalidParams, "Select a single session.") }
            explicit = value
        } else {
            guard !locationSet else { throw Failure(.invalidParams, "Select one session location.") }
            locationSet = true
            location = switch option {
            case "--app-group": .appGroup(value)
            case "--container": .appContainer(value)
            default: .pairingDirectory(URL(fileURLWithPath: value, isDirectory: true))
            }
        }
        arguments.removeFirst(2)
    }
    let defaults = try SessionDefaults.resolve(explicit: explicit)
    let selector = defaults?.selector
    func client() throws -> AgentClient {
        do { return try AgentClient(session: selector, at: location) } catch var failure as Failure where failure.code == .sessionNotFound {
            if let defaults, defaults.source != .flag {
                let origin = defaults.source == .environment ? "$\(SessionDefaults.environmentKey)" : defaults.file?.path ?? SessionDefaults.fileName
                failure = Failure(failure.code, "No live session matches \(defaults.selector) (from \(origin)).", details: failure.details)
            }
            throw failure
        }
    }

    switch arguments {
    case ["--version"]:
        print(AgentDevKitVersion.current)
    case ["--tools-markdown"]:
        // The CLI and MCP tool table in docs/05 and the skill's TOOLS.md, generated from AgentOperation.all.
        print("| MCP tool | CLI | Method | Mutates |")
        print("| --- | --- | --- | --- |")
        print("| `agentdevkit_session` | `session list`, `session ping` | discovery, `system.hello` | no |")
        print("| `agentdevkit_capabilities` | `capabilities` | `system.capabilities` | no |")
        for operation in AgentOperation.all {
            let commands = ([operation.command] + operation.aliases.map(\.command)).map { "`\($0.joined(separator: " "))`" }
            print("| `agentdevkit_\(operation.tool)` | \(commands.joined(separator: ", ")) | `\(operation.method)` | \(operation.mutating ? "yes" : "no") |")
        }
    case ["--help"], ["-h"], ["help"]:
        print(usage)
    case let words where words.first == "help" && words.count > 1:
        let topic = Array(words.dropFirst())
        if let match = AgentOperation.match(topic) {
            print("Usage: " + usage(for: match.operation, command: Array(topic.prefix(match.length)), fixed: match.fixed))
            print(match.operation.summary)
            for field in match.operation.fields where field.flag != nil && match.fixed[field.name] == nil {
                print("  \(field.flag!)\(field.negativeFlag.map { " | \($0)" } ?? "")  \(field.summary)")
            }
        } else {
            print(usage)
        }
    case let words where words.first == "scaffold":
        let options = try Scaffold.parse(words.dropFirst())
        let written: [String]
        do { written = try Scaffold.run(options) } catch let failure as Failure { throw failure } catch {
            throw Failure(.invalidParams, "The files could not be written to \(options.output.path).")
        }
        if json {
            try printJSON(written)
        } else {
            print(written.map { "  " + $0 }.joined(separator: "\n"))
            print("")
            print(Scaffold.steps(options))
        }
    case ["session", "list"] where explicit == nil:
        let sessions = try AgentClient.sessions(at: location)
        let marked = defaults.flatMap { wanted in sessions.first { $0.sessionId.uuidString == wanted.selector || $0.bundleId == wanted.selector } }
        if json {
            struct Listed: Encodable {
                let sessions: [SessionIdentity]
                let defaultSessionId: UUID?
                let defaultSource: String?
            }
            // Keep the v0.5 shape (an array) unless a default applies.
            if let marked, let defaults {
                try printJSON(Listed(sessions: sessions, defaultSessionId: marked.sessionId, defaultSource: defaults.source.rawValue))
            } else {
                try printJSON(sessions)
            }
        } else if sessions.isEmpty {
            print("No live AgentDevKit sessions.")
        } else {
            for session in sessions {
                let mark = session.sessionId == marked?.sessionId ? "  (default, from \(defaults!.source.rawValue))" : ""
                print("\(session.sessionId)  \(session.bundleId)  PID \(session.pid)  \(session.protocolVersion)\(mark)")
            }
        }
    case ["session", "ping"]:
        let response = try await client().hello()
        if json {
            try printJSON(response)
        } else if let app = response.result {
            print("\(app.bundleId)  PID \(app.pid)  \(app.protocolVersion)  \(app.sessionId)")
        }
    case ["capabilities"]:
        let response = try await client().capabilities()
        if json {
            try printJSON(response)
        } else if let capabilities = response.result {
            print(capabilities.methods.joined(separator: "\n"))
        }
    case let words where words.first == "launch":
        exit(try await Launch.run(Array(words.dropFirst()), json: json, location: location))
    case let words where words.first == "doctor":
        exit(try await Doctor.run(Array(words.dropFirst()), json: json, selector: selector, location: location))
    case let words where words.first == "audit-release":
        exit(try await AuditRelease.run(Array(words.dropFirst()), json: json))
    case let words where words.starts(with: ["recipe", "run"]):
        exit(try await Recipes.run(Array(words.dropFirst(2)), json: json, client: client()))
    case let words where words.starts(with: ["recipe", "record"]):
        exit(try Recipes.record(Array(words.dropFirst(2)), json: json))
    case let words where words.starts(with: ["tcc", "reset"]):
        exit(try TCC.reset(Array(words.dropFirst(2)), json: json, selector: selector, location: location))
    case let words where words.first == "desktop":
        exit(try Desktop.forward(Array(words.dropFirst()), selector: selector, location: location, json: json))
    case let words where words.first == "invariants" && words.contains("--watch"):
        exit(try await Watch.invariants(Array(words.dropFirst()), json: json, client: client()))
    default:
        guard let match = AgentOperation.match(arguments) else {
            throw Failure(.invalidParams, "Unknown command. Run agentdevctl --help.")
        }
        let operation = match.operation
        let commandUsage = usage(for: operation, command: Array(arguments.prefix(match.length)), fixed: match.fixed)
        var options = Array(arguments.dropFirst(match.length))
        var output: String?
        if operation.image, let index = options.firstIndex(of: "--out") {
            guard index + 1 < options.count else { throw UsageError(message: "Missing value for --out.", usage: commandUsage) }
            output = options[index + 1]
            options.removeSubrange(index...(index + 1))
        }
        var (values, timeoutMs): ([String: JSONValue], Int?)
        do { (values, timeoutMs) = try parseOptions(options[...], for: operation) } catch let failure as Failure {
            throw UsageError(message: failure.message, usage: commandUsage)
        }
        values.merge(match.fixed) { _, fixed in fixed }
        let single = values.removeValue(forKey: "field")?.stringValue
        let selected = values.removeValue(forKey: "fields")?.arrayValue?.compactMap(\.stringValue)
        let baseline = Baselines.Options(values: &values)
        let session = try client()
        var response = try await operation.run(session, values, timeoutMs: timeoutMs)
        if let note = response.objectValue?["recovery"]?.stringValue { printError(note) }
        Recording.append(operation: operation, values: values, fixed: match.fixed,
                         observedField: single.flatMap { name in operation.field(name, in: response).map { (name, $0) } })
        if let single {
            guard let value = operation.field(single, in: response) else {
                printError("FIELD_NOT_FOUND  \(single) is not in the result.")
                exit(4)
            }
            print(AgentOperation.raw(value))
            exit(0)
        }
        if let selected {
            let projection = operation.select(selected, in: response)
            print(NameSuggestions.compactJSON(projection.object))
            if !projection.missing.isEmpty { printError("Absent: \(projection.missing.joined(separator: ", "))") }
            exit(projection.missing.isEmpty ? 0 : 4)
        }
        var baselineReport: Baselines.Report?
        if operation.image, case .object(var envelope) = response, case .object(let result)? = envelope["result"] {
            var image = operation.imagePath.reduce(Optional(JSONValue.object(result))) { $0?.objectValue?[$1] }?.objectValue ?? [:]
            if let encoded = image["data"]?.stringValue, let data = Data(base64Encoded: encoded) {
                if let baseline { baselineReport = try Baselines.compare(data, capture: image, options: baseline) }
                if let output {
                    let url = URL(filePath: output)
                    do { try data.write(to: url, options: .atomic) } catch {
                        throw Failure(.invalidParams, "The image could not be written to \(output).")
                    }
                    image["data"] = nil
                    image["path"] = .string(url.standardizedFileURL.path)
                } else if baseline != nil || !json {
                    image["data"] = nil
                }
                var updated = JSONValue.object(result)
                updated = Baselines.replacing(updated, at: operation.imagePath, with: .object(image))
                if let baselineReport, case .object(var object) = updated {
                    object["baseline"] = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(baselineReport))) ?? .null
                    updated = .object(object)
                }
                envelope["result"] = updated
                response = .object(envelope)
            }
        }
        if json {
            try printJSON(response)
        } else if let result = response.objectValue?["result"] {
            print(operation.render(result))
            if let baselineReport { print(baselineReport.line) }
        }
        if let baselineReport, !baselineReport.matched { exit(4) }
    }
} catch let error as UsageError {
    if json {
        try? printJSON(Response<EmptyParameters>(error: Failure(.invalidParams, error.message, details: ["usage": .string(error.usage)])))
    } else {
        printError("INVALID_PARAMS  \(error.message)\nUsage: \(error.usage)")
    }
    exit(2)
} catch {
    let failure = error as? Failure ?? Failure(.internalError, "Command failed.")
    if json {
        try? printJSON(Response<EmptyParameters>(requestId: failure.requestId, error: failure))
    } else {
        printError("\(failure.code.rawValue)  \(failure.message)")
        if let closest = failure.details?["closest"]?.stringValue, !failure.message.contains("Did you mean") {
            printError("Did you mean \(closest)?")
        }
        if failure.details?["closest"] == nil, let valid = failure.details?["validNames"]?.arrayValue, !valid.isEmpty, valid.count <= 24 {
            printError("Valid: " + valid.compactMap(\.stringValue).joined(separator: ", "))
        }
        if let example = failure.details?["example"]?.stringValue { printError("Try: \(example)") }
        if let paths = failure.details?["paths"]?.arrayValue, failure.code == .ambiguousElement {
            printError("Candidates:\n" + paths.compactMap(\.stringValue).map { "  --path \(NameSuggestions.shellQuoted($0))" }.joined(separator: "\n"))
        }
        if let remedy = failure.details?["remedy"]?.stringValue { printError(remedy) }
        if failure.code == .conflict, let operation = failure.details?["operationId"]?.stringValue {
            printError("A tracked operation holds the mutation slot. Wait for it: agentdevctl wait --operation \(operation)")
        }
        if let hint = failure.details?["hint"]?.stringValue { printError(hint) }
    }
    exit(failure.code.exitCode)
}

/// Maps CLI options to operation field values. Every option appears at most once.
func parseOptions(_ arguments: ArraySlice<String>, for operation: AgentOperation) throws -> ([String: JSONValue], Int?) {
    var values: [String: JSONValue] = [:]
    var timeoutMs: Int?
    var seen: Set<String> = []
    var iterator = arguments.makeIterator()
    while let flag = iterator.next() {
        guard seen.insert(flag).inserted else { throw Failure(.invalidParams, "Repeated option \(flag).") }
        if flag == "--timeout-ms" {
            guard let text = iterator.next(), let value = Int(text) else { throw Failure(.invalidParams, "Invalid value for --timeout-ms.") }
            timeoutMs = value
            continue
        }
        guard let field = operation.fields.first(where: { $0.flag == flag || $0.negativeFlag == flag }) else {
            let flags = operation.fields.compactMap(\.flag) + operation.fields.compactMap(\.negativeFlag) + ["--timeout-ms", "--json"]
            let closest = NameSuggestions.closest(flag, in: flags)
            throw Failure(.invalidParams, "Unexpected option \(flag).\(closest.map { " Did you mean \($0)?" } ?? "")")
        }
        guard values[field.name] == nil else { throw Failure(.invalidParams, "Conflicting options for \(field.name).") }
        if field.kind == .boolean {
            values[field.name] = .bool(flag == field.flag)
            continue
        }
        guard let text = iterator.next(), !text.hasPrefix("--") else {
            throw Failure(.invalidParams, "Missing value for \(flag).")
        }
        let value: JSONValue? = switch field.kind {
        case .string, .uuid, .oneOf: .string(text)
        case .integer: Int64(text).map(JSONValue.integer)
        case .number: Double(text).map { $0.rounded() == $0 && abs($0) < 1e15 ? .integer(Int64($0)) : .number($0) }
        case .object: try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        // Bare text such as `--value results` is a string.
        case .json: (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        case .stringList: .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        case .boolean: nil
        }
        guard let value else { throw Failure(.invalidParams, "Invalid value for \(flag).") }
        values[field.name] = value
    }
    return (values, timeoutMs)
}
