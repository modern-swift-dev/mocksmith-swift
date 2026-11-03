import Testing

/// A trait that runs each test with its own static mock registry.
///
/// Apply it to a test with `@Test(.isolatedStaticMocks)` or to every test in a suite with
/// `@Suite(.isolatedStaticMocks)`. See `withIsolatedStaticMocks(isolation:_:)` for which calls the
/// isolated registry covers.
public struct IsolatedStaticMocksTrait: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool {
        true
    }

    public func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withIsolatedStaticMocks {
            try await function()
        }
    }
}

public extension Trait where Self == IsolatedStaticMocksTrait {
    /// Runs each test with its own static mock registry.
    static var isolatedStaticMocks: Self {
        Self()
    }
}
