import AgentDevKitCore
import Foundation

public struct CommandContext: Sendable {
    public let requestId: UUID
    public let deadline: ContinuousClock.Instant
    let started: ContinuousClock.Instant

    public func checkDeadline() throws {
        if Task.isCancelled { throw Failure(.cancelled, "Request cancelled.") }
        guard ContinuousClock.now < deadline else { throw Failure(.timeout, "Request deadline elapsed.") }
    }

    var durationMs: Int {
        let components = started.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

public struct AppCommand: Sendable {
    let method: String
    let mutating: Bool
    let run: @Sendable (Data, CommandContext) async throws -> Data

    public init<Input, Output>(
        _ command: Command<Input, Output>,
        mutating: Bool = false,
        parameterKeys: Set<String>,
        accepted: @escaping @Sendable (Output) -> Bool = { _ in false },
        handler: @escaping @MainActor @Sendable (Input, CommandContext) async throws -> Output
    ) {
        method = command.method
        self.mutating = mutating
        run = { data, context in
            let input: Input
            do {
                let envelope = try JSONDecoder().decode(Parameters<Input>.self, from: data)
                guard envelope.keys.isSubset(of: parameterKeys) else {
                    throw Failure(.invalidParams, "Unexpected parameter field.")
                }
                input = envelope.value
            } catch {
                throw Failure(.invalidParams, "Parameters do not match the command schema.")
            }
            try context.checkDeadline()
            let result = try await handler(input, context)
            try context.checkDeadline()
            return try JSONEncoder().encode(Response(
                requestId: context.requestId, result: result, durationMs: context.durationMs,
                accepted: accepted(result)
            ))
        }
    }
}

private struct Parameters<Value: Decodable>: Decodable {
    let value: Value
    let keys: Set<String>

    init(from decoder: any Decoder) throws {
        let envelope = try decoder.container(keyedBy: EnvelopeKey.self)
        let params = try envelope.superDecoder(forKey: .params)
        keys = Set(try params.container(keyedBy: FieldKey.self).allKeys.map(\.stringValue))
        value = try Value(from: params)
    }

    private enum EnvelopeKey: String, CodingKey { case params }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
