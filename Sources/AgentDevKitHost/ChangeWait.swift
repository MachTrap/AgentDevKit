import AgentDevKitCore

/// Observe state changes without polling and release the subscription on every exit.
@MainActor
public func waitForChange<Value: Sendable>(
    until deadline: ContinuousClock.Instant,
    changes: AsyncStream<Void>,
    timeout: @escaping @MainActor () -> Failure,
    evaluate: () throws -> Value?
) async throws -> Value {
    if let result = try evaluate() { return result }
    let (ticks, timer) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in changes {
                timer.yield(false)
            }
        }
        group.addTask {
            guard (try? await ContinuousClock().sleep(until: deadline)) != nil else { return }
            timer.yield(true)
            timer.finish()
        }
        defer {
            group.cancelAll()
            timer.finish()
        }
        for await timedOut in ticks {
            if timedOut || ContinuousClock.now >= deadline { throw timeout() }
            if let result = try evaluate() { return result }
        }
        throw Failure(.cancelled, "Request cancelled.")
    }
}
