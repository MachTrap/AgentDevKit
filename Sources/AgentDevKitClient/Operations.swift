import AgentDevKitCore
import Foundation

/// One bridge command as both tools present it. The CLI and the MCP sidecar are generated
/// from `AgentOperation.all`, so their names, fields, defaults and descriptions cannot drift.
public struct AgentOperation: Sendable {
    public enum Kind: Sendable, Equatable {
        case string
        case uuid
        case integer(minimum: Int, maximum: Int? = nil)
        case number
        case boolean
        case object
        case json
        case oneOf([String])
        /// A list of strings; comma-separated on the command line.
        case stringList
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
        /// A client-side option, such as `--until` or `--wait`, that is never sent as a request param.
        public let local: Bool
        public let summary: String

        public init(_ path: String..., kind: Kind, required: Bool = false, defaultValue: JSONValue? = nil,
                    flag: String? = nil, negativeFlag: String? = nil, mcp: Bool = true, local: Bool = false, summary: String) {
            self.negativeFlag = negativeFlag
            self.path = path
            self.kind = kind
            self.required = required
            self.defaultValue = defaultValue
            self.flag = flag
            self.mcp = mcp
            self.local = local
            self.summary = summary
        }

        public var name: String { path.joined(separator: ".") }
    }

    /// Another CLI spelling of the same operation with some fields fixed, such as `ui set` for `ui.perform`.
    public struct Alias: Sendable {
        public let command: [String]
        public let fixed: [String: JSONValue]
        public let summary: String
    }

    /// MCP tool name without the `agentdevkit_` prefix.
    public let tool: String
    /// CLI command words, such as `["scenario", "prepare"]`.
    public let command: [String]
    public let aliases: [Alias]
    public let method: String
    public let summary: String
    public let fields: [Field]
    public let mutating: Bool
    public let destructive: Bool
    /// The result carries a base64 image in `data` with its `format`, at `imagePath` inside the result.
    /// The CLI writes it to `--out`; the MCP sidecar returns it as image content.
    public let image: Bool
    public let imagePath: [String]
    /// Where app state fields sit in the result, for `--field` and `--fields`. Nil when the result has none.
    public let fieldsPath: [String]?
    /// The result may be `accepted` with an `operationId` that `--wait` follows to completion.
    public let tracked: Bool
    /// One-line text rendering of a successful result for the CLI.
    public let render: @Sendable (JSONValue) -> String
    private let send: @Sendable (AgentClient, [String: JSONValue], Int?, UUID) async throws -> JSONValue

    init<Input, Output>(
        tool: String, command: [String], _ definition: Command<Input, Output>, summary: String,
        fields: [Field] = [], aliases: [Alias] = [], destructive: Bool = false, image: Bool = false, imagePath: [String] = [],
        fieldsPath: [String]? = nil, tracked: Bool = false, render: @escaping @Sendable (JSONValue) -> String
    ) {
        self.image = image
        self.imagePath = imagePath
        self.tool = tool
        self.command = command
        self.aliases = aliases
        self.method = definition.method
        self.summary = summary
        self.fields = fields
        self.mutating = definition.mutating
        self.destructive = destructive
        self.fieldsPath = fieldsPath
        self.tracked = tracked
        self.render = render
        send = { client, params, timeoutMs, requestId in
            let input: Input
            do { input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(params)) }
            catch { throw Failure(.invalidParams, "Arguments do not match the operation schema.") }
            let response = try await client.call(definition, input, timeoutMs: timeoutMs, requestId: requestId)
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
        }
    }

    /// Builds params from field values keyed by field name, applying defaults and checking required fields.
    /// Local options are checked but not included.
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
            if field.local { continue }
            params = Self.insert(value, at: field.path[...], into: params)
        }
        return params
    }

    /// The longest wait the tools accept. Longer waits are split into requests within the session's limit.
    public static let maxWaitMs = 120_000

    /// Sends the operation and returns the response envelope as JSON.
    /// - A `runtime.wait` longer than the session's `maxTimeoutMs` runs as consecutive waits, so no single request
    ///   holds a connection longer than the host allows. `everyMs` shortens each request.
    /// - With the local `wait` option, an `accepted` tracked result is followed to completion.
    /// - A mutation whose connection dropped asks `operations.status` whether it applied before reporting.
    public func run(_ client: AgentClient, _ values: [String: JSONValue], timeoutMs: Int? = nil) async throws -> JSONValue {
        var values = values
        let follow = values["wait"]?.boolValue == true && values["async"]?.boolValue != true
        let everyMs = values["everyMs"]?.integerValue.map(Int.init)
        if method == AppCommands.wait.method, let until = values.removeValue(forKey: "until") {
            guard let text = until.stringValue else { throw Failure(.invalidParams, "until must be a string.", details: ["field": "until"]) }
            try Self.applyUntil(text, to: &values)
        }
        if method == AppCommands.wait.method, values["condition"] == nil {
            guard values["arguments.operationId"] != nil else {
                throw Failure(.invalidParams, "Pass --condition, --until or --operation.", details: ["field": "condition"])
            }
            values["condition"] = "operation.completed"
        }
        var params = try params(values)
        let limit = client.limits.maxTimeoutMs
        let requestId = UUID()
        guard method == AppCommands.wait.method, let total = timeoutMs, total > min(limit, everyMs ?? limit) else {
            let response: JSONValue
            do {
                response = try await send(client, params, timeoutMs, requestId)
            } catch let failure as Failure where mutating && failure.requestId == nil && [.connectionLost, .timeout].contains(failure.code) {
                response = try await Self.reconcile(failure, client: client, requestId: requestId)
            }
            if follow, method == OperatorCommands.ask.method, let operation = Self.operationId(in: response) {
                return try await Self.answer(operation, client: client, original: response)
            }
            guard follow, tracked, response.objectValue?["status"]?.stringValue == "accepted",
                  let operation = Self.operationId(in: response) else { return response }
            return try await Self.follow(operation, client: client, original: response)
        }
        guard total <= Self.maxWaitMs else {
            throw Failure(.invalidParams, "Waits are limited to \(Self.maxWaitMs) ms.", details: ["field": "timeoutMs"])
        }
        let chunk = min(limit, max(100, everyMs ?? limit))
        let failOnTimeout = params["failOnTimeout"]?.boolValue ?? true
        params["failOnTimeout"] = false
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(total)
        var last: JSONValue
        repeat {
            let remaining = clock.now.duration(to: deadline).components
            let remainingMs = Int(remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)
            last = try await send(client, params, min(chunk, max(remainingMs, 100)), UUID())
            if last.objectValue?["result"]?.objectValue?["satisfied"]?.boolValue == true { return last }
        } while clock.now < deadline - .milliseconds(100)
        guard failOnTimeout else { return last }
        let blockers = last.objectValue?["result"]?.objectValue?["blockers"] ?? .array([])
        throw Failure(.timeout, "Condition did not settle before the deadline.", retryable: true, details: ["blockers": blockers])
    }

    /// `phase=results` → `state.field_equals` with `field` and a JSON value (or the raw text); `screen.ready` → that condition.
    public static func applyUntil(_ until: String, to values: inout [String: JSONValue]) throws {
        let text = until.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw Failure(.invalidParams, "until is empty.", details: ["field": "until"]) }
        guard values["condition"] == nil else {
            throw Failure(.invalidParams, "Pass either --until or --condition.", details: ["field": "until"])
        }
        guard let equals = text.firstIndex(of: "=") else {
            values["condition"] = .string(text)
            return
        }
        guard equals > text.startIndex, text[text.index(before: equals)] != "!" else {
            throw Failure(.invalidParams, "Use FIELD=VALUE, such as phase=results.", details: ["field": "until"])
        }
        let field = text[..<equals].trimmingCharacters(in: .whitespaces)
        var rest = text[text.index(after: equals)...]
        if rest.hasPrefix("=") { rest = rest.dropFirst() }
        let raw = rest.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { throw Failure(.invalidParams, "until needs a field name.", details: ["field": "until"]) }
        values["condition"] = "state.field_equals"
        values["arguments.field"] = .string(field)
        values["arguments.value"] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
    }

    static func operationId(in response: JSONValue) -> UUID? {
        let result = response.objectValue?["result"]?.objectValue
        return (result?["operationId"]?.stringValue ?? result?["fixture"]?.objectValue?["operationId"]?.stringValue)
            .flatMap(UUID.init(uuidString:))
    }

    /// Asks whether a mutation applied after its connection dropped. A completed request with a retained result is
    /// returned as success with a `recovery` note; anything else rethrows with `details.status` and a remedy.
    public static func reconcile(_ failure: Failure, client: AgentClient, requestId: UUID) async throws -> JSONValue {
        var status: OperationStatus?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            do {
                status = try await client.call(OperationCommands.status, OperationStatusRequest(requestId: requestId), timeoutMs: 1_000).result
                if status?.state != .pending || attempt == 2 { break }
            } catch let lookup as Failure where lookup.code == .unknownMethod {
                var details = failure.details ?? [:]
                details["remedy"] = "This host has no operations.status. Read the state before retrying."
                throw Failure(failure.code, failure.message, retryable: failure.retryable, details: details)
            } catch {
                continue
            }
        }
        guard let status else {
            var details = failure.details ?? [:]
            details["remedy"] = "The session did not answer operations.status. Read the state before retrying."
            throw Failure(failure.code, failure.message, retryable: failure.retryable, details: details)
        }
        if status.state == .completed, let result = status.result {
            return .object([
                "protocol": .string(Wire.version), "requestId": .string(requestId.uuidString), "ok": true, "status": "completed",
                "result": result, "recovery": .string("Connection lost; \(status.summary).")
            ])
        }
        if status.state == .pending {
            // The host has the request and is still running it: the same as an accepted reply.
            let operation = status.operationId ?? requestId
            return .object([
                "protocol": .string(Wire.version), "requestId": .string(requestId.uuidString), "ok": true, "status": "accepted",
                "result": ["operationId": .string(operation.uuidString), "method": status.method.map(JSONValue.string) ?? .null],
                "recovery": .string("Connection lost; the request is still running as operation \(operation.uuidString).")
            ])
        }
        var details = failure.details ?? [:]
        details["requestId"] = .string(requestId.uuidString)
        details["status"] = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(status))) ?? .null
        details["remedy"] = .string(status.summary.prefix(1).uppercased() + status.summary.dropFirst() + ".")
        throw Failure(failure.code, failure.message, retryable: status.state == .unknown, details: details)
    }

    /// Waits for an operator question to be answered or time out, then returns the answer.
    static func answer(_ operation: UUID, client: AgentClient, original: JSONValue) async throws -> JSONValue {
        guard let wait = all.first(where: { $0.method == AppCommands.wait.method }) else { return original }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1_800)
        while clock.now < deadline {
            let reply = try await wait.run(client, ["condition": "lifecycle.ended", "arguments.operationId": .string(operation.uuidString),
                                                    "failOnTimeout": false], timeoutMs: maxWaitMs)
            if reply.objectValue?["result"]?.objectValue?["satisfied"]?.boolValue == true { break }
        }
        let response = try await client.call(OperatorCommands.answer, OperatorAnswerRequest(operationId: operation))
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
    }

    /// Waits for a tracked operation, then returns its final result from `operations.status`.
    static func follow(_ operation: UUID, client: AgentClient, original: JSONValue) async throws -> JSONValue {
        guard let wait = all.first(where: { $0.method == AppCommands.wait.method }) else { return original }
        _ = try await wait.run(client, ["condition": "operation.completed", "arguments.operationId": .string(operation.uuidString),
                                        "failOnTimeout": true], timeoutMs: maxWaitMs)
        let status = try await client.call(OperationCommands.status, OperationStatusRequest(operationId: operation)).result
        guard let status else { return original }
        switch status.state {
        case .completed:
            var envelope = original.objectValue ?? [:]
            envelope["status"] = "completed"
            envelope["result"] = status.result ?? (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(status))) ?? .null
            return .object(envelope)
        case .failed, .cancelled:
            throw Failure(Failure.Code(status.code ?? (status.state == .cancelled ? "CANCELLED" : "INTERNAL_ERROR")),
                          status.reason ?? "The operation \(status.state.rawValue).", details: status.details)
        case .pending, .unknown:
            throw Failure(.timeout, "The operation did not finish in time.", retryable: true,
                          details: ["operationId": .string(operation.uuidString)])
        }
    }

    // MARK: Field projection

    /// The value at a dotted path in the result's app fields, or in the state object itself (`revision`, `ready`).
    public func field(_ path: String, in response: JSONValue) -> JSONValue? {
        guard let fieldsPath, let result = response.objectValue?["result"] else { return nil }
        let state = fieldsPath.dropLast().reduce(Optional(result)) { $0?.objectValue?[$1] }
        let fields = fieldsPath.reduce(Optional(result)) { $0?.objectValue?[$1] }
        return fields.flatMap { Self.value(at: path, in: $0) } ?? state.flatMap { Self.value(at: path, in: $0) }
    }

    /// The listed fields as one flat JSON object keyed by path, and the paths that were absent.
    public func select(_ paths: [String], in response: JSONValue) -> (object: JSONValue, missing: [String]) {
        var object: [String: JSONValue] = [:]
        var missing: [String] = []
        for path in paths {
            if let value = field(path, in: response) { object[path] = value } else { missing.append(path) }
        }
        return (.object(object), missing)
    }

    /// `a.b.0.c` through objects and arrays.
    public static func value(at path: String, in root: JSONValue) -> JSONValue? {
        var current: JSONValue? = root
        for part in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch current {
            case .object(let object)?: current = object[part]
            case .array(let array)?:
                // Not a ternary: a bare nil there would become JSONValue.null, which is ExpressibleByNilLiteral.
                guard let index = Int(part), array.indices.contains(index) else { return nil }
                current = array[index]
            default: return nil
            }
        }
        return current
    }

    /// A raw value for a shell: strings unquoted, everything else as compact JSON.
    public static func raw(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return NameSuggestions.compactJSON(value)
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
        case (.string, .string), (.boolean, .bool), (.object, .object), (.json, _), (.number, .integer), (.number, .number): true
        case (.uuid, .string(let text)): UUID(uuidString: text) != nil
        case (.oneOf(let values), .string(let text)): values.contains(text)
        case (.integer(let minimum, let maximum), .integer(let number)):
            number >= minimum && maximum.map { number <= $0 } ?? true
        case (.stringList, .array(let items)): items.allSatisfy { $0.stringValue != nil }
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
    private static let window = Field("windowId", kind: .string, flag: "--window",
                                      summary: "Window or surface ID, identifier prefix or title. Defaults to the main window.")
    private static let follow = Field("wait", kind: .boolean, flag: "--wait", local: true,
                                      summary: "When the reply is accepted, wait up to 120 s for the tracked operation and return its final result.")
    private static let async = Field("async", kind: .boolean, flag: "--async", mcp: false, local: true,
                                     summary: "Return as soon as the host answers, even when the reply is accepted (the default).")
    private static let projection = [
        Field("field", kind: .string, flag: "--field", mcp: false, local: true,
              summary: "Print one field's raw value: strings unquoted, others as JSON. Dotted paths reach nested values. Exit 4 when absent."),
        Field("fields", kind: .stringList, flag: "--fields", local: true,
              summary: "Return only these fields (comma-separated on the command line) as one JSON object keyed by path."),
    ]
    private static let locator = [
        Field("identifier", kind: .string, flag: "--id", summary: "Accessibility identifier from ui_tree."),
        Field("path", kind: .string, flag: "--path", summary: "Element path from ui_tree, such as cleanupQueue/queueRow[3]/checkbox."),
        Field("role", kind: .string, flag: "--role", summary: "Role without the AX prefix, such as checkbox or button. Combine with label."),
        Field("label", kind: .string, flag: "--label", summary: "The element's title, description or value text."),
        Field("index", kind: .integer(minimum: 0, maximum: 100), flag: "--index", summary: "Which match when several elements match."),
        window,
    ]
    private static let point = [
        Field("x", kind: .number, flag: "--x", summary: "Window x in points from the left, instead of an element."),
        Field("y", kind: .number, flag: "--y", summary: "Window y in points from the top, instead of an element."),
    ]

    private static func screenLine(_ screen: JSONValue?) -> String {
        let object = screen?.objectValue ?? [:]
        let id = object["screenId"]?.stringValue ?? "?"
        let revision = object["revision"]?.integerValue.map(String.init) ?? "?"
        let ready = object["ready"]?.boolValue.map(String.init) ?? "?"
        return "\(id)  revision \(revision)  ready=\(ready)"
    }

    private static func acceptedLine(_ result: JSONValue) -> String? {
        let object = result.objectValue ?? [:]
        let operation = object["operationId"]?.stringValue ?? object["fixture"]?.objectValue?["operationId"]?.stringValue
        return operation.map { "accepted, still running  operation \($0)  (wait with --wait or: agentdevctl wait --operation \($0))" }
    }

    public static let all: [AgentOperation] = [
        AgentOperation(
            tool: "prepare", command: ["scenario", "prepare"], AppCommands.prepare,
            summary: "Reset isolated Testing data to a named fixture and open a real app screen in one call. Waits for readiness by default. Work that outlasts the deadline answers accepted with an operationId; pass wait=true to follow it. Use external UI checks to verify rendering or clickability.",
            fields: [fixture, Field("fixtureArguments", kind: .object, flag: "--fixture-args",
                                    summary: "Fixture arguments matching capabilities.fixtureArguments[fixture]."),
                     route, context, waitForReady, follow, async], destructive: true, tracked: true
        ) { result in
            if result.objectValue?["operationId"] != nil, let line = acceptedLine(result) { return line }
            return "\(result.objectValue?["fixture"]?.objectValue?["fixture"]?.stringValue ?? "?") → \(screenLine(result.objectValue?["screen"]))"
        },
        AgentOperation(
            tool: "fixtures", command: ["fixtures", "load"], AppCommands.load,
            summary: "Replace isolated Testing data with a named fixture without navigating. Slow loads answer accepted with an operationId; pass wait=true to follow it. Prefer prepare when a screen is also needed.",
            fields: [fixture, Field("arguments", kind: .object, flag: "--fixture-args",
                                    summary: "Fixture arguments matching capabilities.fixtureArguments[fixture]."), follow, async],
            destructive: true, tracked: true
        ) { result in
            if result.objectValue?["operationId"] != nil, let line = acceptedLine(result) { return line }
            return "Loaded \(result.objectValue?["fixture"]?.stringValue ?? "?")  revision \(result.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "navigate", command: ["navigation", "open"], AppCommands.open,
            summary: "Open a registered route through the app's navigation model. Use this for setup and use real UI input when testing the user path.",
            fields: [route, context, waitForReady]
        ) { screenLine($0) },
        AgentOperation(
            tool: "state", command: ["state"], AppCommands.snapshot,
            summary: "Read the scoped app model, readiness blockers and event revision. Pass fields to return only some fields. Use an external accessibility tool to inspect the rendered tree.",
            fields: [scope] + projection, fieldsPath: ["fields"]
        ) { screenLine($0) },
        AgentOperation(
            tool: "observe", command: ["observe"], AppCommands.observe,
            summary: "Read scoped state and the events since a prior revision together, plus invariant violations since then. If the cursor expired, returns a fresh snapshot with resynced=true. If delta.hasMore, continue from delta.nextRevision.",
            fields: [scope, Field("sinceRevision", kind: .integer(minimum: 0), flag: "--since", summary: "Revision from an earlier snapshot."), limit]
                + projection, fieldsPath: ["screen", "fields"]
        ) { result in
            let object = result.objectValue ?? [:]
            let delta = object["delta"]?.objectValue
            let progress = delta.map { "\($0["events"]?.arrayValue?.count ?? 0) events  next revision \($0["nextRevision"]?.integerValue ?? 0)  more=\($0["hasMore"]?.boolValue ?? false)" }
                ?? (object["resynced"]?.boolValue == true ? "cursor expired, fresh snapshot" : "snapshot")
            let violations = object["violations"]?.arrayValue.map { "  \($0.count) invariant violations" } ?? ""
            return "\(screenLine(object["screen"]))  \(progress)\(violations)"
        },
        AgentOperation(
            tool: "wait", command: ["wait"], AppCommands.wait,
            summary: "Wait for an observed condition: screen.ready, work.quiescent, operation.completed, lifecycle.ended, state.field_equals, invariants.hold, or an app condition listed in capabilities. until=\"phase=results\" is shorthand for state.field_equals. Timeouts report the open blockers. Set failOnTimeout=false to get satisfied=false instead of an error.",
            fields: [
                Field("condition", kind: .string, flag: "--condition", summary: "Condition ID from capabilities. camelCase spellings of built-in IDs are accepted."),
                Field("until", kind: .string, flag: "--until", local: true,
                      summary: "FIELD=VALUE waits for state.field_equals (VALUE is JSON, or text); a bare name waits for that condition."),
                scope,
                Field("arguments", kind: .object, flag: "--args", summary: "Condition arguments, such as {\"operationId\": UUID} or {\"field\": NAME, \"value\": JSON}."),
                Field("arguments", "operationId", kind: .uuid, flag: "--operation", mcp: false, summary: "Shorthand for arguments.operationId."),
                Field("arguments", "field", kind: .string, flag: "--field", mcp: false, summary: "Shorthand for arguments.field."),
                Field("arguments", "value", kind: .json, flag: "--value", mcp: false, summary: "Shorthand for arguments.value as JSON."),
                Field("failOnTimeout", kind: .boolean, flag: "--fail-on-timeout", negativeFlag: "--no-fail-on-timeout",
                      summary: "Return TIMEOUT when unsatisfied (default true)."),
                Field("everyMs", kind: .integer(minimum: 100, maximum: 10_000), flag: "--every-ms", local: true,
                      summary: "Split a long wait into requests of at most this many milliseconds."),
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
            summary: "Read recent sanitized diagnostic summaries, newest first. Match correlationId to a command or event. Categories include invariant, experiment and operator when those features are registered.",
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
            tool: "operations", command: ["operations", "list"], OperationCommands.list,
            summary: "List open screen, work and scenario spans with their age, any progress the app reports, and awaitingUser while a panel waits for a person. Use it to see what the app is busy with before waiting."
        ) { result in
            let operations = result.arrayValue ?? []
            guard !operations.isEmpty else { return "No open operations." }
            return operations.map { item in
                let object = item.objectValue ?? [:]
                let progress = object["completed"]?.integerValue.map { done in "  \(done)/\(object["total"]?.integerValue.map(String.init) ?? "?")" } ?? ""
                let waiting = object["awaitingUser"]?.boolValue == true ? "  awaiting user" : ""
                return "\(object["kind"]?.stringValue ?? "?") \(object["name"]?.stringValue ?? "?")  \(object["ageMs"]?.integerValue ?? 0) ms\(progress)\(waiting)  \(object["id"]?.stringValue ?? "")"
            }.joined(separator: "\n")
        },
        AgentOperation(
            tool: "operation_status", command: ["operations", "status"], OperationCommands.status,
            summary: "Report whether a mutating request or tracked operation applied: pending, completed (with its revision and retained result), failed with a reason, cancelled, or unknown. Read-only; use it after CONNECTION_LOST before retrying.",
            fields: [Field("requestId", kind: .uuid, flag: "--request", summary: "Request ID of the earlier mutation."),
                     Field("operationId", kind: .uuid, flag: "--operation", summary: "Operation ID from an accepted reply.")]
        ) { result in
            guard let status = try? JSONDecoder().decode(OperationStatus.self, from: JSONEncoder().encode(result)) else { return "?" }
            return "\(status.state.rawValue)  \(status.summary)\(status.method.map { "  \($0)" } ?? "")"
        },
        AgentOperation(
            tool: "actions", command: ["actions", "list"], AppCommands.actions,
            summary: "List semantic actions, their input schemas, whether each is enabled on the current screen, and presentsUI for actions that open panels."
        ) { result in
            (result.arrayValue ?? []).map {
                "\($0.objectValue?["id"]?.stringValue ?? "?")  enabled=\($0.objectValue?["enabled"]?.boolValue ?? false)\($0.objectValue?["presentsUI"]?.boolValue == true ? "  presents UI" : "")"
            }.joined(separator: "\n")
        },
        AgentOperation(
            tool: "invoke", command: ["action", "invoke"], AppCommands.invoke,
            summary: "Invoke one enabled semantic action in isolated Testing data. This is not a physical click: it cannot prove that a control is visible, hittable or focusable. Actions that present UI or outlast the deadline answer accepted with an operationId; pass wait=true to follow. Supply expectedRevision to reject stale state.",
            fields: [
                Field("actionId", kind: .string, required: true, flag: "--id", summary: "Action ID from actions."),
                Field("arguments", kind: .object, required: true, defaultValue: [:], flag: "--args", summary: "Arguments matching the action's inputSchema."),
                Field("expectedRevision", kind: .integer(minimum: 0), flag: "--revision", summary: "Fail with STALE_REVISION if state changed after this revision."),
                follow, async,
            ],
            destructive: true, tracked: true
        ) { result in
            let object = result.objectValue ?? [:]
            if object["outcome"]?.stringValue == "accepted", let line = acceptedLine(result) { return "\(object["actionId"]?.stringValue ?? "?") \(line)" }
            return "\(object["actionId"]?.stringValue ?? "?") \(object["outcome"]?.stringValue ?? "?")  revision \(object["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "capture", command: ["ui", "capture"], UICommands.capture,
            summary: "Render the app's UI to an image, in process, without Screen Recording permission. The default active mode draws the main window plus every sheet, popover and alert above it; mode=window draws one window; surfaceId draws one surface from ui_surfaces. It shows whatever the window shows.",
            fields: [window,
                     Field("mode", kind: .oneOf(["active", "window"]), flag: "--mode", summary: "active (default): main window plus the surfaces above it. window: one window."),
                     Field("surfaceId", kind: .string, flag: "--surface", summary: "Capture only this surface ID from ui_surfaces."),
                     Field("revision", kind: .integer(minimum: 0), flag: "--revision", summary: "Fail with STALE_REVISION unless state is still at this revision."),
                     Field("format", kind: .oneOf(["png", "jpeg"]), flag: "--format", summary: "png (default) or jpeg. Large captures switch to JPEG to fit the response limit."),
                     Field("maxDimension", kind: .integer(minimum: 64, maximum: 4_096), flag: "--max-dimension", summary: "Longest image side in pixels (default 1600)."),
                     Field("method", kind: .oneOf(["composite", "display"]), flag: "--method",
                           summary: "composite (default): AppKit drawing plus the content of Liquid Glass views drawn in place. display: AppKit drawing only."),
                     Field("baseline", kind: .string, flag: "--baseline", mcp: false, local: true,
                           summary: "Compare with this PNG. {locale} and {appearance} in the path are filled from the capture."),
                     Field("threshold", kind: .number, flag: "--threshold", mcp: false, local: true,
                           summary: "Largest fraction of differing pixels that still matches (default 0.01)."),
                     Field("updateBaseline", kind: .boolean, flag: "--update-baseline", mcp: false, local: true,
                           summary: "Write the capture as the new baseline.")],
            image: true
        ) { result in
            let object = result.objectValue ?? [:]
            let size = "\(object["width"]?.integerValue ?? 0)×\(object["height"]?.integerValue ?? 0)"
            let where_ = object["path"]?.stringValue.map { " → \($0)" } ?? "  (pass --out FILE to save it)"
            let layers = (object["surfaces"]?.arrayValue?.count).map { $0 > 1 ? "  \($0) surfaces" : "" } ?? ""
            return "\(object["title"]?.stringValue ?? "window")  \(size) \(object["format"]?.stringValue ?? "")  \(object["bytes"]?.integerValue ?? 0) bytes\(layers)\(where_)"
        },
        AgentOperation(
            tool: "ui_surfaces", command: ["ui", "surfaces"], UICommands.surfaces,
            summary: "List the app's visible surfaces, front to back: windows, sheets, popovers, panels, alerts and open menus, with IDs to pass as windowId or surfaceId, parent IDs, frames and which window captures default to."
        ) { result in
            let surfaces = result.objectValue?["surfaces"]?.arrayValue ?? []
            guard !surfaces.isEmpty else { return "No visible surfaces." }
            return surfaces.map { item in
                let object = item.objectValue ?? [:]
                let frame = (object["frame"]?.arrayValue ?? []).compactMap(\.doubleValue).map { String(Int($0)) }.joined(separator: ",")
                let marks = [object["isDefault"]?.boolValue == true ? "default" : nil, object["key"]?.boolValue == true ? "key" : nil,
                             object["parentId"]?.stringValue.map { "parent \($0)" }, object["highlightedItem"]?.stringValue.map { "highlighted “\($0)”" }]
                    .compactMap { $0 }.joined(separator: ", ")
                return "\(object["kind"]?.stringValue ?? "?")  \(object["id"]?.stringValue ?? "?")  “\(object["title"]?.stringValue ?? "")”  [\(frame)]\(marks.isEmpty ? "" : "  (\(marks))")"
            }.joined(separator: "\n")
        },
        AgentOperation(
            tool: "ui_snapshot", command: ["ui", "snapshot"], UICommands.snapshot,
            summary: "Capture the active UI, list its accessibility tree and read the state revision in one main-actor turn, so the image, elements and revision agree.",
            fields: [window,
                     Field("mode", kind: .oneOf(["active", "window"]), flag: "--mode", summary: "active (default) or window."),
                     Field("format", kind: .oneOf(["png", "jpeg"]), flag: "--format", summary: "png (default) or jpeg."),
                     Field("maxDimension", kind: .integer(minimum: 64, maximum: 4_096), flag: "--max-dimension", summary: "Longest image side in pixels."),
                     Field("identifierPrefix", kind: .string, flag: "--prefix", summary: "Only elements whose identifier starts with this."),
                     Field("onlyIdentified", kind: .boolean, flag: "--only-identified", summary: "Only elements with an identifier."),
                     Field("limit", kind: .integer(minimum: 1, maximum: 3_000), flag: "--limit", summary: "Most elements (default 400).")],
            image: true, imagePath: ["capture"]
        ) { result in
            let object = result.objectValue ?? [:]
            let capture = object["capture"]?.objectValue ?? [:]
            let count = object["tree"]?.objectValue?["elements"]?.arrayValue?.count ?? 0
            let where_ = capture["path"]?.stringValue.map { " → \($0)" } ?? "  (pass --out FILE to save the image)"
            return "revision \(object["revision"]?.integerValue ?? 0)  \(capture["width"]?.integerValue ?? 0)×\(capture["height"]?.integerValue ?? 0)  \(count) elements\(where_)"
        },
        AgentOperation(
            tool: "ui_tree", command: ["ui", "tree"], UICommands.tree,
            summary: "List a window's accessibility elements in process: role, identifier, label, value and numeric value (secrets redacted), min/max/step, actions, a stable path, frame in window points and state. lint=true reports duplicated identifiers and identifiers SwiftUI copied from a container onto its children.",
            fields: [window,
                     Field("identifierPrefix", kind: .string, flag: "--prefix", summary: "Only elements whose identifier starts with this."),
                     Field("onlyIdentified", kind: .boolean, flag: "--only-identified", summary: "Only elements with an accessibility identifier."),
                     Field("maxDepth", kind: .integer(minimum: 1, maximum: 60), flag: "--max-depth", summary: "Deepest level to report."),
                     Field("limit", kind: .integer(minimum: 1, maximum: 3_000), flag: "--limit", summary: "Most elements to return (default 800)."),
                     Field("lint", kind: .boolean, flag: "--lint", summary: "Report identifier problems and how to fix them."),
                     Field("revision", kind: .integer(minimum: 0), flag: "--revision", summary: "Fail with STALE_REVISION unless state is still at this revision."),
                     Field("source", kind: .oneOf(["accessibility", "appkit", "views"]), flag: "--source",
                           summary: "accessibility (default): the system accessibility tree, as VoiceOver and XCUITest see it. appkit: AppKit accessibility objects. views: the AppKit view hierarchy with class names, for layout and capture diagnosis.")]
        ) { result in
            let elements = result.objectValue?["elements"]?.arrayValue ?? []
            var lines = elements.map { element in
                let object = element.objectValue ?? [:]
                let indent = String(repeating: "  ", count: Int(object["depth"]?.integerValue ?? 0))
                let frame = (object["frame"]?.arrayValue ?? []).compactMap { $0.doubleValue }.map { String(Int($0)) }.joined(separator: ",")
                let text = [object["identifier"]?.stringValue.map { "#\($0)" }, object["label"]?.stringValue.map { "“\($0)”" },
                            object["value"]?.stringValue.map { "= \($0)" }, object["valueDescription"]?.stringValue.map { "(\($0))" }]
                    .compactMap { $0 }.joined(separator: " ")
                return "\(indent)\(object["role"]?.stringValue ?? "?") \(text) [\(frame)]"
            }
            for finding in result.objectValue?["lint"]?.arrayValue ?? [] {
                let object = finding.objectValue ?? [:]
                let paths = (object["paths"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
                lines.append("lint \(object["kind"]?.stringValue ?? "?") #\(object["identifier"]?.stringValue ?? "?"): \(paths)\n  fix: \(object["fix"]?.stringValue ?? "")")
            }
            return lines.joined(separator: "\n")
        },
        AgentOperation(
            tool: "press", command: ["ui", "press"], UICommands.press,
            summary: "Perform the accessibility press action on one element, in process, located by identifier, path, or role and label. Several matches fail with AMBIGUOUS_ELEMENT listing their paths. Closer to the user path than invoke, but not independent evidence: it does not prove hit testing. Use XCUITest for that.",
            fields: locator, destructive: true
        ) { result in
            let object = result.objectValue ?? [:]
            return "Pressed \(object["path"]?.stringValue ?? object["identifier"]?.stringValue ?? "?") (\(object["role"]?.stringValue ?? "?"))  revision \(object["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "ui_perform", command: ["ui", "perform"], UICommands.perform,
            summary: "Drive a real control through accessibility: set a slider, stepper, checkbox or text value; choose a menu or pop-up item; expand or collapse a disclosure or outline row; press, increment or decrement. Returns the element's new value and the state revision. Evidence is accessibility: it proves the control exists, is enabled and responds, not pointer hit testing.",
            fields: [Field("operation", kind: .oneOf(["set", "choose", "expand", "collapse", "press", "increment", "decrement", "dismiss"]), required: true,
                           flag: "--operation", summary: "set, choose, expand, collapse, press, increment, decrement, or dismiss (closes a sheet, panel, alert or popover; item ok or cancel).")]
                + locator + [
                    Field("value", kind: .json, flag: "--value", summary: "For set: a number, boolean or string (JSON; bare text is taken as a string)."),
                    Field("item", kind: .string, flag: "--item", summary: "For choose: the menu item's title or identifier. For dismiss: ok or cancel (default)."),
                ],
            aliases: ["set", "choose", "expand", "collapse", "increment", "decrement", "dismiss"].map {
                Alias(command: ["ui", $0], fixed: ["operation": .string($0)], summary: "ui perform --operation \($0)")
            },
            destructive: true
        ) { result in
            let object = result.objectValue ?? [:]
            let value = object["value"]?.stringValue.map { "  value \($0)" } ?? ""
            return "\(object["operation"]?.stringValue ?? "?") \(object["path"]?.stringValue ?? "?") (\(object["role"]?.stringValue ?? "?"))\(value)  revision \(object["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "ui_key", command: ["ui", "key"], UICommands.key,
            summary: "Send synthesized key events to the app's key window in process: names such as Down, Return, Tab, Escape, a, F5, or cmd+s. Exercises the app's own key handlers, not the system's keyboard routing; use the desktop runner to prove focus order.",
            fields: [Field("keys", kind: .string, required: true, flag: "--keys", summary: "Space-separated key names, such as \"Down Down Return\"."),
                     Field("modifiers", kind: .stringList, flag: "--modifiers", summary: "cmd, shift, option, control applied to every key."),
                     window],
            destructive: true
        ) { result in
            "Sent \(result.objectValue?["events"]?.integerValue ?? 0) key events  revision \(result.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "ui_hover", command: ["ui", "hover"], UICommands.hover,
            summary: "Move a synthesized pointer over an element or window point in process, delivering mouse-moved and enter/exit events to its window and tracking areas, so hover cards and tooltips appear without relying on the real cursor.",
            fields: locator + point, destructive: true
        ) { result in
            let point = (result.objectValue?["point"]?.arrayValue ?? []).compactMap(\.doubleValue).map { String(Int($0)) }.joined(separator: ",")
            return "Hovered at [\(point)]  revision \(result.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "ui_scroll", command: ["ui", "scroll"], UICommands.scroll,
            summary: "Send a synthesized scroll-wheel event over an element or window point in process. Positive dy scrolls the content down.",
            fields: locator + point + [Field("dy", kind: .number, required: true, flag: "--dy", summary: "Points to scroll down; negative scrolls up."),
                                       Field("dx", kind: .number, flag: "--dx", summary: "Points to scroll right.")],
            destructive: true
        ) { result in
            "Scrolled  revision \(result.objectValue?["revision"]?.integerValue ?? 0)"
        },
        AgentOperation(
            tool: "invariants", command: ["invariants"], InvariantCommands.list,
            summary: "List the app's registered invariants with whether each holds now, the revision of each violation, evaluation cost and overBudget flags."
        ) { result in
            let object = result.objectValue ?? [:]
            var lines = (object["invariants"]?.arrayValue ?? []).map { item in
                let entry = item.objectValue ?? [:]
                let details = entry["details"].map { "  \(NameSuggestions.compactJSON($0))" } ?? ""
                let budget = entry["overBudget"]?.boolValue == true ? "  over budget" : ""
                return "\(entry["holds"]?.boolValue == true ? "holds   " : "VIOLATED") \(entry["id"]?.stringValue ?? "?")  \(entry["lastCostMicros"]?.integerValue ?? 0) µs\(budget)\(details)"
            }
            for item in object["violations"]?.arrayValue ?? [] {
                let entry = item.objectValue ?? [:]
                let resolved = entry["resolvedAt"]?.integerValue.map { ", resolved at \($0)" } ?? ", open"
                lines.append("  violation \(entry["id"]?.stringValue ?? "?") at revision \(entry["revision"]?.integerValue ?? 0)\(resolved)")
            }
            return lines.isEmpty ? "No invariants registered." : lines.joined(separator: "\n")
        },
        AgentOperation(
            tool: "operator_ask", command: ["operator", "ask"], OperatorCommands.ask,
            summary: "Ask the person at the Mac a question in a labelled Testing-only panel in the app, for what an agent cannot see or do: system dialogs, hardware, visual judgment. Returns an operationId at once; wait with operation.completed and read the answer with operator_answer, or pass wait=true.",
            fields: [Field("question", kind: .string, required: true, flag: "--question", summary: "The question, up to 1000 bytes."),
                     Field("options", kind: .stringList, flag: "--options", summary: "Button titles, 1…6 (comma-separated on the command line). Default OK."),
                     Field("allowNotes", kind: .boolean, flag: "--notes", summary: "Show a notes field."),
                     Field("answerTimeoutMs", kind: .integer(minimum: 1_000, maximum: 1_800_000), flag: "--answer-timeout-ms",
                           summary: "How long to wait for the person before the answer is unanswered (default 300000)."),
                     follow],
            destructive: true, tracked: true
        ) { result in
            let object = result.objectValue ?? [:]
            if let answer = object["status"]?.stringValue {
                return "\(answer)\(object["answer"]?.stringValue.map { ": \($0)" } ?? "")\(object["notes"]?.stringValue.map { "  notes: \($0)" } ?? "")"
            }
            return "Asked  operation \(object["operationId"]?.stringValue ?? "?")"
        },
        AgentOperation(
            tool: "operator_answer", command: ["operator", "answer"], OperatorCommands.answer,
            summary: "Read the answer to an operator question: pending, answered with the chosen option and notes, or unanswered after the timeout.",
            fields: [Field("operationId", kind: .uuid, required: true, flag: "--operation", summary: "Operation ID from operator_ask.")]
        ) { result in
            let object = result.objectValue ?? [:]
            return "\(object["status"]?.stringValue ?? "?")\(object["answer"]?.stringValue.map { ": \($0)" } ?? "")\(object["notes"]?.stringValue.map { "  notes: \($0)" } ?? "")"
        },
        AgentOperation(
            tool: "experiment", command: ["experiment", "run"], ExperimentCommands.run,
            summary: "Run a registered investigation probe from capabilities.experiments. Each run is recorded as a diagnostic with category experiment, its inputs and results. Probes that are not read-only need a mutation session.",
            fields: [Field("experimentId", kind: .string, required: true, flag: "--id", summary: "Experiment ID from capabilities.experiments."),
                     Field("arguments", kind: .object, flag: "--args", summary: "Arguments matching the experiment's inputSchema.")]
        ) { result in
            let object = result.objectValue ?? [:]
            return "\(object["experimentId"]?.stringValue ?? "?")  \(object["durationMs"]?.integerValue ?? 0) ms  \(NameSuggestions.compactJSON(object["fields"] ?? [:]))"
        },
        AgentOperation(
            tool: "privacy_status", command: ["tcc", "status"], PrivacyCommands.status,
            summary: "Report what the app's own process observes about its privacy grants (Full Disk Access probe, Accessibility, Screen Recording) without reading TCC databases or prompting."
        ) { result in
            let object = result.objectValue ?? [:]
            return ["fullDiskAccess", "accessibility", "screenRecording"].map { "\($0): \(object[$0]?.stringValue ?? "?")" }.joined(separator: "\n")
        },
    ]

    /// The operation and fixed fields for CLI words, such as `ui set` → `ui.perform` with operation=set.
    public static func match(_ words: [String]) -> (operation: AgentOperation, fixed: [String: JSONValue], length: Int)? {
        var best: (AgentOperation, [String: JSONValue], Int)?
        for operation in all {
            for (command, fixed) in [(operation.command, [String: JSONValue]())] + operation.aliases.map({ ($0.command, $0.fixed) })
            where words.starts(with: command) && command.count > (best?.2 ?? 0) {
                best = (operation, fixed, command.count)
            }
        }
        return best
    }
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
