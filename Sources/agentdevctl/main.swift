import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation

let usage = """
Usage:
  agentdevctl session list [--json]
  agentdevctl [--session ID_OR_BUNDLE] session ping [--json]
  agentdevctl [--session ID_OR_BUNDLE] capabilities [--json]
  agentdevctl [--session ID_OR_BUNDLE] state --scope SCOPE [--json]
  agentdevctl [--session ID_OR_BUNDLE] observe [--scope SCOPE] [--since REVISION] [--limit N] [--json]
  agentdevctl [--session ID_OR_BUNDLE] navigation open --route ROUTE [--context JSON] [--no-wait] [--json]
  agentdevctl [--session ID_OR_BUNDLE] fixtures load --fixture FIXTURE [--json]
  agentdevctl [--session ID_OR_BUNDLE] scenario prepare --fixture FIXTURE --route ROUTE [--context JSON] [--no-wait] [--json]
  agentdevctl [--session ID_OR_BUNDLE] wait --condition PREDICATE [--scope SCOPE] [--timeout-ms MS] [--operation UUID | --field KEY --value JSON] [--json]
  agentdevctl [--session ID_OR_BUNDLE] events since --revision REVISION [--limit N] [--json]
  agentdevctl [--session ID_OR_BUNDLE] diagnostics recent [--severity warning|error] [--category CATEGORY] [--limit N] [--json]
  agentdevctl [--session ID_OR_BUNDLE] actions list [--json]
  agentdevctl [--session ID_OR_BUNDLE] action invoke --id ACTION --args JSON [--revision REVISION] [--json]
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
if let index = arguments.firstIndex(of: "--json") { arguments.remove(at: index) }

do {
    var selector: String?
    if arguments.first == "--session", arguments.count >= 2 {
        selector = arguments[1]
        arguments.removeFirst(2)
    }
    switch arguments {
    case ["--help"], ["-h"]:
        print(usage)
    case ["session", "list"] where selector == nil:
        let sessions = try AgentClient.sessions()
        if json {
            try printJSON(sessions)
        } else if sessions.isEmpty {
            print("No live AgentDevKit sessions.")
        } else {
            for session in sessions {
                print("\(session.sessionId)  \(session.bundleId)  PID \(session.pid)")
            }
        }
    case ["session", "ping"]:
        let response = try await AgentClient(session: selector).hello()
        if json {
            try printJSON(response)
        } else if let app = response.result {
            print("\(app.bundleId)  PID \(app.pid)  \(app.protocolVersion)  \(app.sessionId)")
        }
    case ["capabilities"]:
        let response = try await AgentClient(session: selector).capabilities()
        if json {
            try printJSON(response)
        } else if let capabilities = response.result {
            print(capabilities.methods.joined(separator: "\n"))
        }
    case _ where arguments.starts(with: ["state"]):
        let options = try Options(arguments.dropFirst(), allowed: ["--scope"])
        let input = SnapshotRequest(scope: options.values["--scope"] ?? "current-screen")
        let result = try await AgentClient(session: selector).call(AppCommands.snapshot, input)
        try printResult(result) { "\($0.screenId)  revision \($0.revision)  ready=\($0.ready)" }
    case _ where arguments.starts(with: ["navigation", "open"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--route", "--context"], allowWait: true)
        let input = OpenScreen(route: try options.require("--route"), context: try options.context(), waitForReady: options.wait)
        let result = try await AgentClient(session: selector).call(AppCommands.open, input)
        try printResult(result) { "\($0.screenId)  ready=\($0.ready)" }
    case _ where arguments.starts(with: ["fixtures", "load"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--fixture"])
        let input = LoadFixture(fixture: try options.require("--fixture"))
        let result = try await AgentClient(session: selector).call(AppCommands.load, input)
        try printResult(result) { "Loaded \($0.fixture)  revision \($0.revision)" }
    case _ where arguments.starts(with: ["scenario", "prepare"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--fixture", "--route", "--context"], allowWait: true)
        let input = PrepareScenario(
            fixture: try options.require("--fixture"), route: try options.require("--route"),
            context: try options.context(), waitForReady: options.wait
        )
        let result = try await AgentClient(session: selector).call(AppCommands.prepare, input)
        try printResult(result) { "\($0.fixture.fixture) → \($0.screen.screenId)  ready=\($0.screen.ready)" }
    case _ where arguments.starts(with: ["observe"]):
        let options = try Options(arguments.dropFirst(), allowed: ["--scope", "--since", "--limit"])
        let input = ObserveRequest(
            scope: options.values["--scope"] ?? "current-screen",
            sinceRevision: try options.parse("--since", UInt64.init), limit: try options.parse("--limit", Int.init)
        )
        let result = try await AgentClient(session: selector).call(AppCommands.observe, input)
        try printResult(result) {
            let progress = $0.delta.map { "\($0.events.count) events  next revision \($0.nextRevision)  more=\($0.hasMore)" }
                ?? ($0.resynced ? "cursor expired, fresh snapshot" : "snapshot")
            return "\($0.screen.screenId)  revision \($0.screen.revision)  \(progress)"
        }
    case _ where arguments.starts(with: ["wait"]):
        let options = try Options(arguments.dropFirst(), allowed: [
            "--condition", "--scope", "--timeout-ms", "--operation", "--field", "--value"
        ])
        let input = WaitRequest(
            condition: try options.require("--condition"), scope: options.values["--scope"] ?? "current-screen",
            operationId: try options.parse("--operation", UUID.init(uuidString:)),
            field: options.values["--field"], value: try options.decode("--value", as: JSONValue.self)
        )
        let timeout = try options.parse("--timeout-ms", Int.init) ?? Wire.maxTimeoutMs
        let result = try await AgentClient(session: selector).call(AppCommands.wait, input, timeoutMs: timeout)
        try printResult(result) { "Satisfied at revision \($0.screen.revision)" }
    case _ where arguments.starts(with: ["events", "since"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--revision", "--limit"])
        guard let revision = try options.parse("--revision", UInt64.init) else {
            throw Failure(.invalidParams, "Missing --revision.")
        }
        let input = EventsRequest(revision: revision, limit: try options.parse("--limit", Int.init))
        let result = try await AgentClient(session: selector).call(AppCommands.events, input)
        try printResult(result) { "\($0.events.count) events  next revision \($0.nextRevision)  more=\($0.hasMore)" }
    case _ where arguments.starts(with: ["diagnostics", "recent"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--severity", "--category", "--limit"])
        let input = DiagnosticsRequest(
            severity: try options.parse("--severity", DiagnosticRecord.Severity.init(rawValue:)),
            category: options.values["--category"], limit: try options.parse("--limit", Int.init)
        )
        let result = try await AgentClient(session: selector).call(AppCommands.diagnostics, input)
        try printResult(result) { $0.map { "\($0.code)  \($0.message)" }.joined(separator: "\n") }
    case ["actions", "list"]:
        let result = try await AgentClient(session: selector).call(AppCommands.actions, EmptyParameters())
        try printResult(result) { $0.map { "\($0.id)  enabled=\($0.enabled)" }.joined(separator: "\n") }
    case _ where arguments.starts(with: ["action", "invoke"]):
        let options = try Options(arguments.dropFirst(2), allowed: ["--id", "--args", "--revision"])
        guard let args = try options.decode("--args", as: [String: JSONValue].self) else {
            throw Failure(.invalidParams, "Missing --args.")
        }
        let input = ActionRequest(
            actionId: try options.require("--id"), arguments: args, expectedRevision: try options.parse("--revision", UInt64.init)
        )
        let result = try await AgentClient(session: selector).call(AppCommands.invoke, input)
        try printResult(result) { "Saved at revision \($0.revision)" }
    default:
        throw Failure(.invalidParams, usage)
    }
} catch {
    let failure = error as? Failure ?? Failure(.internalError, "Command failed.")
    if json {
        try? printJSON(Response<EmptyParameters>(requestId: failure.requestId, error: failure))
    } else {
        FileHandle.standardError.write(Data("\(failure.code.rawValue)  \(failure.message)\n".utf8))
    }
    switch failure.code {
    case .invalidParams: exit(2)
    case .sessionExpired, .authRequired, .permissionDenied, .conflict: exit(3)
    case .timeout: exit(5)
    case .unsupportedVersion, .appInstanceMismatch: exit(6)
    default: exit(4)
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

@MainActor
func printResult<Output>(_ response: Response<Output>, summary: (Output) -> String) throws {
    if json { try printJSON(response) }
    else if let result = response.result { print(summary(result)) }
}

struct Options {
    private(set) var values: [String: String] = [:]
    private(set) var wait: Bool?
    init(_ arguments: ArraySlice<String>, allowed: Set<String>, allowWait: Bool = false) throws {
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            if allowWait && wait == nil && (flag == "--wait-ready" || flag == "--no-wait") {
                wait = flag == "--wait-ready"
            } else {
                guard allowed.contains(flag), values[flag] == nil, let value = iterator.next(), !value.hasPrefix("--")
                else { throw Failure(.invalidParams, "Unexpected, repeated, or incomplete option.") }
                values[flag] = value
            }
        }
    }

    func require(_ flag: String) throws -> String {
        guard let value = values[flag], !value.isEmpty else { throw Failure(.invalidParams, "Missing \(flag).") }
        return value
    }

    func parse<Value>(_ flag: String, _ parse: (String) -> Value?) throws -> Value? {
        guard let text = values[flag] else { return nil }
        guard let value = parse(text) else { throw Failure(.invalidParams, "Invalid value for \(flag).") }
        return value
    }

    func decode<Value: Decodable>(_ flag: String, as type: Value.Type) throws -> Value? {
        try parse(flag) { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    func context() throws -> RouteContext? {
        guard let text = values["--context"] else { return nil }
        guard let context = try? JSONDecoder().decode(RouteContext.self, from: Data(text.utf8)) else {
            throw Failure(.invalidParams, "Context must be a JSON object with optional projectId and nodeId strings.")
        }
        return context
    }
}
