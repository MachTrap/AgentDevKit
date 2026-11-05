import AgentDevKitCore
import Foundation

/// One bridge command as both tools present it. The CLI and the MCP sidecar are generated
/// from `AgentOperation.all`, so their names, fields, defaults and descriptions cannot drift.
public struct AgentOperation: Sendable {
    public enum Kind: Sendable, Equatable {
        case string
        case uuid
        case integer(minimum: Int, maximum: Int? = nil)
        case boolean
        case object
        case json
        case oneOf([String])
    }

    public struct Field: Sendable {
        /// Path of the field inside the request params. Nested paths fill an object such as `arguments`.
        public let path: [String]
        public let kind: Kind
        public let required: Bool
        public let defaultValue: JSONValue?
        /// CLI option, or nil when the CLI does not expose this field. Boolean options take no value.
        public let flag: String?
        /// CLI option that sets a boolean field to false.
        public let negativeFlag: String?
        /// Whether the MCP tool exposes this field as a top-level property.
        public let mcp: Bool
        public let summary: String

        public init(_ path: String..., kind: Kind, required: Bool = false, defaultValue: JSONValue? = nil,
                    flag: String? = nil, negativeFlag: String? = nil, mcp: Bool = true, summary: String) {
            self.negativeFlag = negativeFlag
            self.path = path
            self.kind = kind
            self.required = required
            self.defaultValue = defaultValue
            self.flag = flag
            self.mcp = mcp
            self.summary = summary
        }

        public var name: String { path.joined(separator: ".") }
    }

    /// MCP tool name without the `agentdevkit_` prefix.
    public let tool: String
    /// CLI command words, such as `["scenario", "prepare"]`.
    public let command: [String]
    public let method: String
    public let summary: String
    public let fields: [Field]
    public let mutating: Bool
    public let destructive: Bool
    /// One-line text rendering of a successful result for the CLI.
    public let render: @Sendable (JSONValue) -> String
    private let send: @Sendable (AgentClient, [String: JSONValue], Int?) async throws -> JSONValue

    init<Input, Output>(
        tool: String, command: [String], _ definition: Command<Input, Output>, summary: String,
        fields: [Field] = [], destructive: Bool = false, render: @escaping @Sendable (JSONValue) -> String
    ) {
        self.tool = tool
        self.command = command
        self.method = definition.method
        self.summary = summary
        self.fields = fields
        self.mutating = definition.mutating
        self.destructive = destructive
        self.render = render
        send = { client, params, timeoutMs in
            let input: Input
            do { input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(params)) }
            catch { throw Failure(.invalidParams, "Arguments do not match the operation schema.") }
            let response = try await client.call(definition, input, timeoutMs: timeoutMs)
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
        }
    }

    /// Builds params from field values keyed by field name, applying defaults and checking required fields.
    public func params(_ values: [String: JSONValue]) throws -> [String: JSONValue] {
        if let unknown = values.keys.first(where: { key in !fields.contains { $0.name == key } }) {
            throw Failure(.invalidParams, "Unexpected argument.", details: ["field": .string(unknown)])
        }
        var params: [String: JSONValue] = [:]
        for field in fields {
            guard let value = values[field.name] ?? field.defaultValue else {
                if field.required { throw Failure(.invalidParams, "Missing required argument.", details: ["field": .string(field.name)]) }
                continue
            }
            try Self.check(value, field)
            params = Self.insert(value, at: field.path[...], into: params)
        }
        return params
    }

    /// The longest wait the tools accept. Longer waits are split into requests within the session's limit.
    public static let maxWaitMs = 120_000

    /// Sends the operation and returns the response envelope as JSON.
    /// A `runtime.wait` longer than the session's `maxTimeoutMs` runs as consecutive waits,
    /// so no single request holds a connection longer than the host allows.
    public func run(_ client: AgentClient, _ values: [String: JSONValue], timeoutMs: Int? = nil) async throws -> JSONValue {
        var params = try params(values)
        let limit = client.limits.maxTimeoutMs
        guard method == AppCommands.wait.method, let total = timeoutMs, total > limit else {
            return try await send(client, params, timeoutMs)
        }
        guard total <= Self.maxWaitMs else {
            throw Failure(.invalidParams, "Waits are limited to \(Self.maxWaitMs) ms.", details: ["field": "timeoutMs"])
        }
        let failOnTimeout = params["failOnTimeout"]?.boolValue ?? true
        params["failOnTimeout"] = false
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(total)
        var last: JSONValue
        repeat {
            let remaining = clock.now.duration(to: deadline).components
            let remainingMs = Int(remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)
            last = try await send(client, params, min(limit, max(remainingMs, 250)))
            if last.objectValue?["result"]?.objectValue?["satisfied"]?.boolValue == true { return last }
        } while clock.now < deadline - .milliseconds(250)
        guard failOnTimeout else { return last }
        let blockers = last.objectValue?["result"]?.objectValue?["blockers"] ?? .array([])
        throw Failure(.timeout, "Condition did not settle before the deadline.", retryable: true, details: ["blockers": blockers])
    }

    private static func insert(_ value: JSONValue, at path: ArraySlice<String>, into object: [String: JSONValue]) -> [String: JSONValue] {
        var object = object
        guard let head = path.first else { return object }
        if path.count == 1 {
            // A whole object field merges with nested values supplied through other fields.
            if case .object(let incoming) = value, case .object(let existing)? = object[head] {
                object[head] = .object(existing.merging(incoming) { _, new in new })
            } else {
                object[head] = value
            }
        } else {
            object[head] = .object(insert(value, at: path.dropFirst(), into: object[head]?.objectValue ?? [:]))
        }
        return object
    }

    private static func check(_ value: JSONValue, _ field: Field) throws {
        let valid = switch (field.kind, value) {
        case (.string, .string), (.boolean, .bool), (.object, .object), (.json, _): true
        case (.uuid, .string(let text)): UUID(uuidString: text) != nil
        case (.oneOf(let values), .string(let text)): values.contains(text)
        case (.integer(let minimum, let maximum), .integer(let number)):
            number >= minimum && maximum.map { number <= $0 } ?? true
        default: false
        }
        guard valid else { throw Failure(.invalidParams, "Argument has the wrong type or range.", details: ["field": .string(field.name)]) }
    }
}

extension AgentOperation {
    private static let scope = Field("scope", kind: .string, defaultValue: "current-screen", flag: "--scope",
                                     summary: "Registered snapshot scope from capabilities. Defaults to current-screen.")
    private static let route = Field("route", kind: .string, required: true, flag: "--route",
                                     summary: "Registered route ID from capabilities.")
    private static let context = Field("context", kind: .object, flag: "--context",
                                       summary: "Route context object matching the route's contextSchema.")
    private static let waitForReady = Field("waitForReady", kind: .boolean, flag: "--wait-ready", negativeFlag: "--no-wait",
                                            summary: "Wait until the screen is ready (default true).")
    private static let fixture = Field("fixture", kind: .string, required: true, flag: "--fixture",
                                       summary: "Registered fixture ID from capabilities.")
    private static let limit = Field("limit", kind: .integer(minimum: 1, maximum: 100), flag: "--limit", summary: "Page size.")

    private static func screenLine(_ screen: JSONValue?) -> String {
        let object = screen?.objectValue ?? [:]
        let id = object["screenId"]?.stringValue ?? "?"
        let revision = object["revision"]?.integerValue.map(String.init) ?? "?"
        let ready = object["ready"]?.boolValue.map(String.init) ?? "?"
        return "\(id)  revision \(revision)  ready=\(ready)"
    }

    public static let all: [AgentOperation] = [
        AgentOperation(
            tool: "prepare", command: ["scenario", "prepare"], AppCommands.prepare,
            summary: "Reset isolated Testing data to a named fixture and open a real app screen in one call. Waits for readiness by default. Use external UI checks to verify rendering or clickability.",
            fields: [fixture, Field("fixtureArguments", kind: .object, flag: "--fixture-args",
                                    summary: "Fixture arguments matching capabilities.fixtureArguments[fixture]."),
                     route, context, waitForReady], destructive: true
        ) { result in
            "\(result.objectValue?["fixture"]?.objectValue?["fixture"]?.stringValue ?? "?") → \(screenLine(result.objectValue?["screen"]))"
        },
        AgentOperation(
            tool: "fixtures", command: ["fixtures", "load"], AppCommands.load,
            summary: "Replace isolated Testing data with a named fixture without navigating. Prefer prepare when a screen is also needed.",
            fields: [fixture, Field("arguments", kind: .object, flag: "--fixture-args",
                                    summary: "Fixture arguments matching capabilities.fixtureArguments[fixture].")], destructive: true
        ) { result in
            "Loaded \(result.objectValue?["fixture"]?.stringValue ?? "?")  revision \(result.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "navigate", command: ["navigation", "open"], AppCommands.open,
            summary: "Open a registered route through the app's navigation model. Use this for setup and use real UI input when testing the user path.",
            fields: [route, context, waitForReady]
        ) { screenLine($0) },
        AgentOperation(
            tool: "state", command: ["state"], AppCommands.snapshot,
            summary: "Read the scoped app model, readiness blockers and event revision. Use an external accessibility tool to inspect the rendered tree.",
            fields: [scope]
        ) { screenLine($0) },
        AgentOperation(
            tool: "observe", command: ["observe"], AppCommands.observe,
            summary: "Read scoped state and the events since a prior revision together. If the cursor expired, returns a fresh snapshot with resynced=true. If delta.hasMore, continue from delta.nextRevision.",
            fields: [scope, Field("sinceRevision", kind: .integer(minimum: 0), flag: "--since", summary: "Revision from an earlier snapshot."), limit]
        ) { result in
            let object = result.objectValue ?? [:]
            let delta = object["delta"]?.objectValue
            let progress = delta.map { "\($0["events"]?.arrayValue?.count ?? 0) events  next revision \($0["nextRevision"]?.integerValue ?? 0)  more=\($0["hasMore"]?.boolValue ?? false)" }
                ?? (object["resynced"]?.boolValue == true ? "cursor expired, fresh snapshot" : "snapshot")
            return "\(screenLine(object["screen"]))  \(progress)"
        },
        AgentOperation(
            tool: "wait", command: ["wait"], AppCommands.wait,
            summary: "Wait for an observed condition: screen.ready, work.quiescent, operation.completed, lifecycle.ended, state.field_equals, or an app condition listed in capabilities. Timeouts report the open blockers. Set failOnTimeout=false to get satisfied=false instead of an error.",
            fields: [
                Field("condition", kind: .string, required: true, flag: "--condition", summary: "Condition ID from capabilities."),
                scope,
                Field("arguments", kind: .object, flag: "--args", summary: "Condition arguments, such as {\"operationId\": UUID} or {\"field\": NAME, \"value\": JSON}."),
                Field("arguments", "operationId", kind: .uuid, flag: "--operation", mcp: false, summary: "Shorthand for arguments.operationId."),
                Field("arguments", "field", kind: .string, flag: "--field", mcp: false, summary: "Shorthand for arguments.field."),
                Field("arguments", "value", kind: .json, flag: "--value", mcp: false, summary: "Shorthand for arguments.value as JSON."),
                Field("failOnTimeout", kind: .boolean, flag: "--fail-on-timeout", negativeFlag: "--no-fail-on-timeout",
                      summary: "Return TIMEOUT when unsatisfied (default true).")
            ]
        ) { result in
            let object = result.objectValue ?? [:]
            guard object["satisfied"]?.boolValue == true else {
                return "Not satisfied  blockers: \(object["blockers"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ",") ?? "")"
            }
            return "Satisfied at revision \(object["screen"]?.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "events", command: ["events", "since"], AppCommands.events,
            summary: "Read bounded changes after a snapshot revision. Continue with nextRevision when hasMore is true. On STALE_REVISION, take a fresh snapshot.",
            fields: [Field("revision", kind: .integer(minimum: 0), required: true, flag: "--revision", summary: "Cursor revision."), limit]
        ) { result in
            let object = result.objectValue ?? [:]
            return "\(object["events"]?.arrayValue?.count ?? 0) events  next revision \(object["nextRevision"]?.integerValue ?? 0)  more=\(object["hasMore"]?.boolValue ?? false)"
        },
        AgentOperation(
            tool: "diagnostics", command: ["diagnostics", "recent"], AppCommands.diagnostics,
            summary: "Read recent sanitized diagnostic summaries, newest first. Match correlationId to a command or event.",
            fields: [
                Field("severity", kind: .oneOf(["warning", "error"]), flag: "--severity", summary: "Minimum severity."),
                Field("category", kind: .string, flag: "--category", summary: "Category from capabilities.diagnosticCategories."),
                Field("limit", kind: .integer(minimum: 1, maximum: 50), flag: "--limit", summary: "Record count.")
            ]
        ) { result in
            (result.arrayValue ?? []).map {
                "\($0.objectValue?["code"]?.stringValue ?? "?")  \($0.objectValue?["message"]?.stringValue ?? "")"
            }.joined(separator: "\n")
        },
        AgentOperation(
            tool: "actions", command: ["actions", "list"], AppCommands.actions,
            summary: "List semantic actions, their input schemas, and whether each is enabled on the current screen."
        ) { result in
            (result.arrayValue ?? []).map {
                "\($0.objectValue?["id"]?.stringValue ?? "?")  enabled=\($0.objectValue?["enabled"]?.boolValue ?? false)"
            }.joined(separator: "\n")
        },
        AgentOperation(
            tool: "invoke", command: ["action", "invoke"], AppCommands.invoke,
            summary: "Invoke one enabled semantic action in isolated Testing data. This is not a physical click: it cannot prove that a control is visible, hittable or focusable. Supply expectedRevision to reject stale state.",
            fields: [
                Field("actionId", kind: .string, required: true, flag: "--id", summary: "Action ID from actions."),
                Field("arguments", kind: .object, required: true, defaultValue: [:], flag: "--args", summary: "Arguments matching the action's inputSchema."),
                Field("expectedRevision", kind: .integer(minimum: 0), flag: "--revision", summary: "Fail with STALE_REVISION if state changed after this revision.")
            ],
            destructive: true
        ) { result in
            let object = result.objectValue ?? [:]
            return "\(object["actionId"]?.stringValue ?? "?") \(object["outcome"]?.stringValue ?? "?")  revision \(object["revision"]?.integerValue ?? 0)"
        }
    ]
}

extension Failure.Code {
    /// Stable process exit codes for command-line tools.
    /// 2 invalid input · 3 session or connection · 4 app-domain failure · 5 timeout · 6 version or identity mismatch.
    public var exitCode: Int32 {
        switch self {
        case .invalidParams, .frameTooLarge: 2
        case .sessionNotFound, .ambiguousSession, .sessionExpired, .connectionLost, .authRequired, .rateLimited: 3
        case .timeout: 5
        case .unsupportedVersion, .appInstanceMismatch, .invalidResponse: 6
        default: 4
        }
    }
}
