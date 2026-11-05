import AgentDevKitCore
import Foundation

public struct CommandContext: Sendable {
    public let requestId: UUID
    public let deadline: ContinuousClock.Instant
    let started: ContinuousClock.Instant
    let sessionId: UUID
    let pid: Int32

    /// The same request with a later deadline, for work that continues after the response.
    func extending(to deadline: ContinuousClock.Instant) -> CommandContext {
        CommandContext(requestId: requestId, deadline: deadline, started: started, sessionId: sessionId, pid: pid)
    }

    public func checkDeadline() throws {
        if Task.isCancelled { throw Failure(.cancelled, "Request cancelled.") }
        guard ContinuousClock.now < deadline else { throw Failure(.timeout, "Request deadline elapsed.") }
    }

    var durationMs: Int {
        let components = started.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    func encode<Output: Codable & Sendable>(_ result: Output, accepted: Bool = false) throws -> Data {
        try JSONEncoder().encode(Response(
            requestId: requestId, result: result, durationMs: durationMs, accepted: accepted,
            sessionId: sessionId, pid: pid
        ))
    }
}

/// A typed handler registered under one method name. The host validates `params`
/// against `parameters` before decoding `Input`, and reports the failing field.
public struct AppCommand: Sendable {
    let method: String
    let mutating: Bool
    let parameters: ObjectSchema
    let run: @Sendable ([String: JSONValue], CommandContext) async throws -> Data
    /// For tracked commands: the `accepted` reply sent when the work outlasts the request deadline.
    /// The work keeps running under the request ID as its operation ID.
    let promote: (@Sendable ([String: JSONValue], CommandContext) async throws -> Data)?

    public init<Input, Output>(
        _ command: Command<Input, Output>,
        parameters: ObjectSchema,
        accepted: @escaping @Sendable (Output) -> Bool = { _ in false },
        handler: @escaping @MainActor @Sendable (Input, CommandContext) async throws -> Output
    ) {
        self.init(command, parameters: parameters, accepted: accepted, promote: nil, handler: handler)
    }

    /// A tracked command. When `handler` outlasts the request deadline, the host replies with `promote`'s
    /// output as `accepted` and lets the handler finish; `operations.status` then reports its result.
    init<Input, Output>(
        _ command: Command<Input, Output>,
        parameters: ObjectSchema,
        accepted: @escaping @Sendable (Output) -> Bool = { _ in false },
        promote: (@MainActor @Sendable (Input, CommandContext) throws -> Output)?,
        handler: @escaping @MainActor @Sendable (Input, CommandContext) async throws -> Output
    ) {
        method = command.method
        mutating = command.mutating
        self.parameters = parameters
        if let promote {
            self.promote = { params, context in
                let input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(params))
                return try context.encode(await promote(input, context), accepted: true)
            }
        } else {
            self.promote = nil
        }
        run = { params, context in
            try parameters.validate(params)
            let input: Input
            do {
                input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(params))
            } catch {
                throw Failure(.invalidParams, "Parameters do not match the command schema.", details: decodingDetails(error))
            }
            try context.checkDeadline()
            let result = try await handler(input, context)
            // A result that finished just past its deadline is still sent: the connection and the client both
            // allow a grace period, and dropping a finished wait or mutation result would hide what happened.
            if Task.isCancelled { throw Failure(.cancelled, "Request cancelled.") }
            guard ContinuousClock.now < context.deadline + .milliseconds(500) else { throw Failure(.timeout, "Request deadline elapsed.") }
            return try context.encode(result, accepted: accepted(result))
        }
    }
}

/// Names the failing parameter path without echoing the supplied value.
func decodingDetails(_ error: any Error) -> [String: JSONValue]? {
    let path: [any CodingKey]
    switch error as? DecodingError {
    case .keyNotFound(let key, let context)?: path = context.codingPath + [key]
    case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .dataCorrupted(let context)?: path = context.codingPath
    default: return nil
    }
    let field = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    return field.isEmpty ? nil : ["field": .string(field)]
}
