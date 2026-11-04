import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation
import MCP

private let sessionSource: SessionSource = {
    let environment = ProcessInfo.processInfo.environment
    let group = environment["AGENTDEVKIT_APP_GROUP"]
    let folder = environment["AGENTDEVKIT_PAIRING_DIR"]
    switch (group, folder) {
    case (nil, nil): return .local
    case (let group?, nil) where !group.isEmpty: return .appGroup(group)
    case (nil, let folder?) where !folder.isEmpty:
        return .pairingDirectory(URL(fileURLWithPath: folder, isDirectory: true))
    default:
        FileHandle.standardError.write(Data("Configure exactly one nonempty AgentDevKit session source.\n".utf8))
        exit(2)
    }
}()

private struct Endpoint: Sendable {
    let tool: Tool
    let run: @Sendable ([String: Value]) async throws -> CallTool.Result

    init(
        _ name: String, description: String, fields: [String: Value] = [:],
        required: [String] = [], mutating: Bool = false, destructive: Bool = false,
        run: @escaping @Sendable ([String: Value]) async throws -> CallTool.Result
    ) {
        var properties = fields
        properties["sessionId"] = [
            "type": "string",
            "description": "Exact session UUID from agentdevkit_session. Required to disambiguate multiple sessions."
        ]
        self.tool = Tool(
            name: "agentdevkit_" + name, description: description,
            inputSchema: [
                "type": "object", "properties": .object(properties), "additionalProperties": false,
                "required": .array(required.map(Value.string))
            ],
            annotations: .init(readOnlyHint: !mutating, destructiveHint: destructive, openWorldHint: false),
            outputSchema: ["type": "object", "required": ["ok"], "properties": ["ok": ["type": "boolean"]]]
        )
        let validKeys = Set(properties.keys)
        self.run = { arguments in
            guard Set(arguments.keys).isSubset(of: validKeys),
                  required.allSatisfy({ arguments[$0] != nil }) else {
                throw Failure(.invalidParams, "Tool arguments do not match the schema.")
            }
            if arguments["sessionId"] != nil {
                guard let selector = arguments["sessionId"]?.stringValue, UUID(uuidString: selector) != nil else {
                    throw Failure(.invalidParams, "sessionId must be an exact session UUID.")
                }
            }
            return try await run(arguments)
        }
    }

    static func command<Input, Output>(
        _ name: String, _ command: Command<Input, Output>, description: String, fields: [String: Value] = [:],
        required: [String] = [], mutating: Bool = false, destructive: Bool = false, acceptsTimeout: Bool = false
    ) -> Endpoint {
        var schema = fields
        if acceptsTimeout {
            schema["timeoutMs"] = ["type": "integer", "minimum": 1, "maximum": .int(Wire.maxTimeoutMs)]
        }
        return Endpoint(name, description: description, fields: schema, required: required,
                        mutating: mutating, destructive: destructive) { arguments in
            var input = arguments
            let selector = input.removeValue(forKey: "sessionId")?.stringValue
            let timeout: Int
            if let supplied = input.removeValue(forKey: "timeoutMs") {
                guard case let .int(milliseconds) = supplied else {
                    throw Failure(.invalidParams, "timeoutMs must be an integer.")
                }
                timeout = milliseconds
            } else {
                timeout = Wire.maxTimeoutMs
            }
            let params: Input
            do {
                let data = try JSONEncoder().encode(input)
                guard data.count <= Wire.maxRequestBytes else {
                    throw Failure(.frameTooLarge, "Tool arguments exceed the request budget.")
                }
                params = try JSONDecoder().decode(Input.self, from: data)
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(.invalidParams, "Tool argument types do not match the schema.")
            }
            return try result(await AgentClient(session: selector, source: sessionSource).call(command, params, timeoutMs: timeout))
        }
    }
}

private struct SessionList: Codable {
    let ok: Bool
    let result: [SessionIdentity]
}

private func result(_ payload: some Codable, isError: Bool = false) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let value = try JSONDecoder().decode(Value.self, from: data)
    return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                 structuredContent: Optional(value), isError: isError)
}

private let string: Value = ["type": "string"]
private let boolean: Value = ["type": "boolean"]
private let limit: Value = ["type": "integer", "minimum": 1]
private let cursor: Value = ["type": "integer", "minimum": 0]
private let context: Value = [
    "type": "object", "properties": ["projectId": string, "nodeId": string], "additionalProperties": false
]

private let endpoints: [Endpoint] = [
    Endpoint("session", description: "List opted-in native app sessions. With a sessionId, verify that exact live app's identity.") { args in
        if let id = args["sessionId"]?.stringValue {
            return try result(await AgentClient(session: id, source: sessionSource).hello())
        }
        return try result(SessionList(ok: true, result: AgentClient.sessions(source: sessionSource)))
    },
    Endpoint("capabilities", description: "Discover the selected session's current methods, permitted routes, fixtures, scopes, and limits.") { args in
        try result(await AgentClient(session: args["sessionId"]?.stringValue, source: sessionSource).capabilities())
    },
    .command("prepare", AppCommands.prepare, description: "Reset isolated Testing data to a named fixture and open a real app screen. Waits for readiness by default. Use external UI checks to verify rendering or clickability.",
             fields: ["fixture": string, "route": string, "context": context, "waitForReady": boolean],
             required: ["fixture", "route"], mutating: true, destructive: true),
    .command("navigate", AppCommands.open, description: "Open a registered route through the app's navigation model. Use this for setup and use real UI input when testing the user path.",
             fields: ["route": string, "context": context, "waitForReady": boolean], required: ["route"], mutating: true),
    .command("state", AppCommands.snapshot, description: "Read the scoped app model, readiness blockers and event revision. Use an external accessibility tool to inspect the rendered tree.",
             fields: ["scope": string], required: ["scope"]),
    .command("observe", AppCommands.observe, description: "Read scoped app state and the events since a prior revision together. If the cursor expired, returns a fresh snapshot with resynced=true. If delta.hasMore, continue from delta.nextRevision.",
             fields: ["scope": string, "sinceRevision": cursor, "limit": limit], required: ["scope"]),
    .command("wait", AppCommands.wait, description: "Wait for an observed state change. Supported conditions include screen.ready, work.quiescent, operation.completed, lifecycle.ended and state.field_equals. Timeout errors name observed blockers.",
             fields: ["condition": string, "scope": string, "operationId": string, "field": string, "value": .object([:])],
             required: ["condition", "scope"], acceptsTimeout: true),
    .command("events", AppCommands.events, description: "Read bounded changes after a snapshot revision. Continue with nextRevision when hasMore is true. On STALE_REVISION, get a fresh snapshot.",
             fields: ["revision": cursor, "limit": limit], required: ["revision"]),
    .command("diagnostics", AppCommands.diagnostics, description: "Read recent sanitized diagnostic summaries. Use correlationId to match a command or event when available.",
             fields: ["severity": ["type": "string", "enum": ["warning", "error"]], "category": string, "limit": limit]),
    .command("actions", AppCommands.actions, description: "List the selected app's semantic actions, their inputs, and whether each is enabled on the current screen."),
    .command("invoke", AppCommands.invoke, description: "Invoke one enabled semantic action in the isolated Testing workspace. Use physical UI input to verify clickability. Supply expectedRevision to reject stale state.",
             fields: ["actionId": string, "arguments": ["type": "object"], "expectedRevision": cursor],
             required: ["actionId", "arguments"], mutating: true, destructive: true)
]

let server = Server(name: "agentdevkit", version: "0.2.0", capabilities: .init(tools: .init()))
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: endpoints.map(\.tool))
}
await server.withMethodHandler(CallTool.self) { call in
    do {
        guard let endpoint = endpoints.first(where: { $0.tool.name == call.name }) else {
            throw Failure(.unknownMethod, "Tool is not registered.")
        }
        return try await endpoint.run(call.arguments ?? [:])
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
