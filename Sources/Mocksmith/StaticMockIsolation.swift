/// Runs `body` with a fresh static mock registry, so static mocks stubbed, called, and verified inside
/// it don't share state with other tests running in parallel.
///
/// The registry is bound as a task-local value. It covers `body`, the child tasks it creates, and
/// unstructured `Task`s started inside it. Calls made from `Task.detached`, Dispatch queues, or other
/// threads that don't inherit task-local values use the process-wide registry instead.
public func withIsolatedStaticMocks<Result>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Result
) async rethrows -> Result {
    try await StaticMockRegistry.$isolated.withValue(StaticMockRegistry(), operation: body, isolation: isolation)
}
