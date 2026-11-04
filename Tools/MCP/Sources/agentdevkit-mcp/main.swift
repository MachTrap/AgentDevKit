import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation
import MCP

// Stdout carries MCP frames only. Diagnostics go to stderr.

private let location: SessionLocation = {
    let environment = ProcessInfo.processInfo.environment
    let group = environment["AGENTDEVKIT_APP_GROUP"]
    let folder = environment["AGENTDEVKIT_PAIRING_DIR"]
    switch (group, folder) {
    case (nil, nil): return .local
    case (let group?, nil) where !group.isEmpty: return .appGroup(group)
    case (nil, let folder?) where !folder.isEmpty:
        return .pairingDirectory(URL(fileURLWithPath: folder, isDirectory: true))
    default:
        FileHandle.standardError.write(Data("Configure exactly one nonempty AgentDevKit session location.\n".utf8))
        exit(2)
    }
}()

private struct Endpoint: Sendable {
    let tool: Tool
    let run: @Sendable (_ selector: String?, _ arguments: [String: JSONValue], _ timeoutMs: Int?) async throws -> CallTool.Result
}

private let sessionField: Value = [
    "type": "string",
    "description": "Session UUID or bundle ID from agentdevkit_session. Required when more than one session is live."
]
private let timeoutField: Value = [
    "type": "integer", "minimum": 1, "maximum": .int(Wire.timeoutCeilingMs),
    "description": "Request deadline in milliseconds, up to the session's limits.maxTimeoutMs."
]

private func schema(_ kind: AgentOperation.Kind) -> Value {
    switch kind {
    case .string: ["type": "string"]
    case .uuid: ["type": "string", "format": "uuid"]
    case .integer(let minimum, let maximum):
        maximum.map { ["type": "integer", "minimum": .int(minimum), "maximum": .int($0)] } ?? ["type": "integer", "minimum": .int(minimum)]
    case .boolean: ["type": "boolean"]
    case .object: ["type": "object"]
    case .json: [:]
    case .oneOf(let values): ["type": "string", "enum": .array(values.map(Value.string))]
    }
}

private func tool(_ name: String, _ description: String, fields: [String: Value] = [:], required: [String] = [],
                  mutating: Bool = false, destructive: Bool = false) -> Tool {
    var properties = fields
    properties["sessionId"] = sessionField
    properties["timeoutMs"] = timeoutField
    return Tool(
        name: "agentdevkit_" + name, description: description,
        inputSchema: [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
            "required": .array(required.map(Value.string))
        ],
        annotations: .init(readOnlyHint: !mutating, destructiveHint: destructive, openWorldHint: false),
        outputSchema: ["type": "object", "required": ["ok"], "properties": ["ok": ["type": "boolean"]]]
    )
}

private func result(_ payload: some Encodable, isError: Bool = false) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let value = try JSONDecoder().decode(Value.self, from: data)
    // Resolve the SDK's nonthrowing Value initializer consistently across Swift versions.
    let makeResult: ([Tool.Content], Value?, Bool?, Metadata?) -> CallTool.Result = CallTool.Result.init
    let content: Tool.Content = .text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)
    return makeResult([content], value, isError, nil)
}

private struct SessionList: Encodable {
    let ok: Bool
    let result: [SessionIdentity]
}

private let endpoints: [Endpoint] = [
    Endpoint(tool: tool("session", "List opted-in native app sessions with their protocol versions. With a sessionId, verify that exact live app's identity.")) { selector, _, timeoutMs in
        guard let selector else { return try result(SessionList(ok: true, result: AgentClient.sessions(at: location))) }
        return try result(await AgentClient(session: selector, at: location).hello())
    },
    Endpoint(tool: tool("capabilities", "Discover the selected session's methods, routes with context schemas, fixtures, scopes, actions, wait conditions, lifecycle names and limits.")) { selector, _, timeoutMs in
        try result(await AgentClient(session: selector, at: location).capabilities(timeoutMs: timeoutMs))
    }
] + AgentOperation.all.map { operation in
    let exposed = operation.fields.filter(\.mcp)
    let fields = Dictionary(exposed.map { field in
        var property = schema(field.kind).objectValue ?? [:]
        property["description"] = .string(field.summary)
        return (field.name, Value.object(property))
    }, uniquingKeysWith: { first, _ in first })
    let required = exposed.filter { $0.required && $0.defaultValue == nil }.map(\.name)
    return Endpoint(tool: tool(operation.tool, operation.summary, fields: fields, required: required,
                               mutating: operation.mutating, destructive: operation.destructive)) { selector, arguments, timeoutMs in
        guard Set(arguments.keys).isSubset(of: Set(exposed.map(\.name))) else {
            throw Failure(.invalidParams, "Tool arguments do not match the schema.")
        }
        let client = try AgentClient(session: selector, at: location)
        return try result(await operation.run(client, arguments, timeoutMs: timeoutMs))
    }
}

let server = Server(name: "agentdevkit", version: AgentDevKitVersion.current, capabilities: .init(tools: .init()))
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: endpoints.map(\.tool))
}
await server.withMethodHandler(CallTool.self) { call in
    do {
        guard let endpoint = endpoints.first(where: { $0.tool.name == call.name }) else {
            throw Failure(.unknownMethod, "Tool is not registered.")
        }
        var arguments: [String: JSONValue]
        do { arguments = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(call.arguments ?? [:])) }
        catch { throw Failure(.invalidParams, "Tool arguments must be a JSON object.") }
        let selector = arguments.removeValue(forKey: "sessionId")
        let timeout = arguments.removeValue(forKey: "timeoutMs")
        guard selector == nil || selector?.stringValue?.isEmpty == false else {
            throw Failure(.invalidParams, "sessionId must be a session UUID or bundle ID.")
        }
        guard timeout == nil || timeout?.integerValue != nil else { throw Failure(.invalidParams, "timeoutMs must be an integer.") }
        return try await endpoint.run(selector?.stringValue, arguments, timeout?.integerValue.map(Int.init))
    } catch {
        let failure = error as? Failure ?? Failure(.internalError, "Tool call failed.")
        return try result(Response<EmptyParameters>(requestId: failure.requestId, error: failure), isError: true)
    }
}

do {
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("AgentDevKit MCP stdio transport failed.\n".utf8))
    exit(1)
}
