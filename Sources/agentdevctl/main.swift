import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation

let usage: String = {
    var lines = [
        "Usage:",
        "  agentdevctl --version",
        "  Global options (before the command): --session ID_OR_BUNDLE · --app-group ID | --pairing-dir PATH | --container BUNDLE_ID",
        "  A bundle ID passed to --session also finds a sandboxed app's session in its own container.",
        "  agentdevctl session list [--json]",
        "  agentdevctl [--session ID_OR_BUNDLE] session ping [--json]",
        "  agentdevctl [--session ID_OR_BUNDLE] capabilities [--json]"
    ]
    for operation in AgentOperation.all {
        let options = operation.fields.compactMap { field -> String? in
            guard let flag = field.flag else { return nil }
            let option: String
            if field.kind == .boolean {
                option = field.negativeFlag.map { "\(flag) | \($0)" } ?? flag
            } else {
                option = "\(flag) \(field.path.last!.uppercased())"
            }
            return field.required ? option : "[\(option)]"
        }
        lines.append("  agentdevctl [--session ID_OR_BUNDLE] " + (operation.command + options + ["[--timeout-ms MS]", "[--json]"]).joined(separator: " "))
    }
    lines.append("Exit codes: 0 ok · 2 invalid input · 3 session or connection · 4 app failure · 5 timeout · 6 version or identity mismatch")
    return lines.joined(separator: "\n")
}()

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

do {
    var selector: String?
    var location: SessionLocation = .local
    var locationSet = false
    while let option = arguments.first, ["--session", "--app-group", "--pairing-dir", "--container"].contains(option) {
        guard arguments.count >= 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else {
            throw Failure(.invalidParams, "Missing value for \(option).")
        }
        let value = arguments[1]
        if option == "--session" {
            guard selector == nil else { throw Failure(.invalidParams, "Select a single session.") }
            selector = value
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
    switch arguments {
    case ["--version"]:
        print(AgentDevKitVersion.current)
    case ["--help"], ["-h"]:
        print(usage)
    case ["session", "list"] where selector == nil:
        let sessions = try AgentClient.sessions(at: location)
        if json {
            try printJSON(sessions)
        } else if sessions.isEmpty {
            print("No live AgentDevKit sessions.")
        } else {
            for session in sessions {
                print("\(session.sessionId)  \(session.bundleId)  PID \(session.pid)  \(session.protocolVersion)")
            }
        }
    case ["session", "ping"]:
        let response = try await AgentClient(session: selector, at: location).hello()
        if json {
            try printJSON(response)
        } else if let app = response.result {
            print("\(app.bundleId)  PID \(app.pid)  \(app.protocolVersion)  \(app.sessionId)")
        }
    case ["capabilities"]:
        let response = try await AgentClient(session: selector, at: location).capabilities()
        if json {
            try printJSON(response)
        } else if let capabilities = response.result {
            print(capabilities.methods.joined(separator: "\n"))
        }
    default:
        guard let operation = AgentOperation.all.first(where: { arguments.starts(with: $0.command) }) else {
            throw Failure(.invalidParams, usage)
        }
        let (values, timeoutMs) = try parseOptions(arguments.dropFirst(operation.command.count), for: operation)
        let client = try AgentClient(session: selector, at: location)
        let response = try await operation.run(client, values, timeoutMs: timeoutMs)
        if json {
            try printJSON(response)
        } else if let result = response.objectValue?["result"] {
            print(operation.render(result))
        }
    }
} catch {
    let failure = error as? Failure ?? Failure(.internalError, "Command failed.")
    if json {
        try? printJSON(Response<EmptyParameters>(requestId: failure.requestId, error: failure))
    } else {
        FileHandle.standardError.write(Data("\(failure.code.rawValue)  \(failure.message)\n".utf8))
        if let remedy = failure.details?["remedy"]?.stringValue {
            FileHandle.standardError.write(Data("\(remedy)\n".utf8))
        }
    }
    exit(failure.code.exitCode)
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
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
            throw Failure(.invalidParams, "Unexpected option \(flag). Run agentdevctl --help.")
        }
        guard values[field.name] == nil else { throw Failure(.invalidParams, "Conflicting options for \(field.name).") }
        if field.kind == .boolean {
            values[field.name] = .bool(flag == field.flag)
            continue
        }
        guard let text = iterator.next(), !text.hasPrefix("--") else { throw Failure(.invalidParams, "Missing value for \(flag).") }
        let value: JSONValue? = switch field.kind {
        case .string, .uuid, .oneOf: .string(text)
        case .integer: Int64(text).map(JSONValue.integer)
        case .object, .json: try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        case .boolean: nil
        }
        guard let value else { throw Failure(.invalidParams, "Invalid value for \(flag).") }
        values[field.name] = value
    }
    return (values, timeoutMs)
}
