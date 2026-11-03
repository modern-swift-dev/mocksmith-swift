import Foundation
import Synchronization

/// Thread-safe, count-only runtime channel for transient arguments and results.
public final class TransientMockMember<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable
>: Sendable {
    private struct State {
        /// Recorded sequences in ascending order; assigning them under the lock keeps them sorted.
        var invocations: [UInt64] = []
        var verifiedSequences: Set<UInt64> = []
        // Sound: the mutex guards every access; user matchers, actions, and outcomes are registered on
        // one thread and run on invoking threads, which is the mock's documented contract.
        nonisolated(unsafe) var configuration = MockConfiguration<Arguments, Ephemeral, TransientStubOutcome<Arguments, Ephemeral, Output>>()
    }

    private let state = Mutex(State())
    private let name: String

    public init(name: String = "member") {
        self.name = name
    }

    @discardableResult public func addStub(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
    ) -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output> {
        precondition(!outcomes.isEmpty, "Mock stubs need at least one outcome")
        let id = state.withLock { $0.configuration.addStub(matching: matching, specificity: specificity, outcomes: outcomes) }
        return _MocksmithTransientStubRegistration { [self] outcomes in
            state.withLock { $0.configuration.appendOutcomes(outcomes, toStub: id) }
        }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        state.withLock { $0.configuration.addAction(matching: matching, specificity: specificity, body: action) }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (borrowing Arguments) -> Void
    ) where Ephemeral == Void {
        addAction(matching: matching, specificity: specificity) { arguments, _ in
            action(arguments)
        }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>],
        action: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        precondition(!outcomes.isEmpty, "Mock stubs need at least one outcome")
        state.withLock { $0.configuration.addAction(matching: matching, specificity: specificity, outcomes: outcomes, body: action) }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>],
        action: @escaping (borrowing Arguments) -> Void
    ) where Ephemeral == Void {
        addAction(matching: matching, specificity: specificity, outcomes: outcomes) { arguments, _ in
            action(arguments)
        }
    }

    public func invoke(_ arguments: borrowing Arguments, ephemeral: borrowing Ephemeral, unstubbed: (() -> Output)? = nil) throws -> Output {
        guard let outcome = selectOutcome(for: arguments, ephemeral: ephemeral) else {
            if let unstubbed {
                return unstubbed()
            }
            throw MockError.unstubbed(name)
        }
        switch outcome {
            case let .produce(producer): return producer()
            case let .throwError(error): throw error
            case let .answer(answer): return try answer(arguments, ephemeral)
            case .asyncAnswer:
                preconditionFailure("Async mock answer requires async invocation")
        }
    }

    public func invoke(_ arguments: borrowing Arguments) throws -> Output where Ephemeral == Void {
        try invoke(arguments, ephemeral: ())
    }

    public func invoke(_ arguments: borrowing Arguments, unstubbed: (() -> Output)?) throws -> Output where Ephemeral == Void {
        try invoke(arguments, ephemeral: (), unstubbed: unstubbed)
    }

    public func invokeAsync(
        _ arguments: borrowing Arguments,
        ephemeral: borrowing Ephemeral,
        unstubbed: (@Sendable () -> Output)? = nil
    ) async throws -> Output {
        guard let outcome = selectOutcome(for: arguments, ephemeral: ephemeral) else {
            if let unstubbed {
                return unstubbed()
            }
            throw MockError.unstubbed(name)
        }
        switch outcome {
            case let .produce(producer): return producer()
            case let .throwError(error): throw error
            case let .answer(answer): return try answer(arguments, ephemeral)
            case let .asyncAnswer(answer): return try await answer(arguments)
        }
    }

    public func invokeAsync(_ arguments: borrowing Arguments) async throws -> Output where Ephemeral == Void {
        try await invokeAsync(arguments, ephemeral: ())
    }

    public func invokeAsync(
        _ arguments: borrowing Arguments,
        unstubbed: (@Sendable () -> Output)?
    ) async throws -> Output where Ephemeral == Void {
        try await invokeAsync(arguments, ephemeral: (), unstubbed: unstubbed)
    }

    public func record() {
        state.withLock { $0.invocations.append(nextMockInvocationSequence()) }
    }

    public var invocationCount: Int {
        state.withLock { $0.invocations.count }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        state.withLock { state in
            state.invocations.map { .init(sequence: $0, member: name) }
        }
    }

    public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        state.withLock { state in
            state.invocations.compactMap {
                state.verifiedSequences.contains($0) ? nil : .init(sequence: $0, member: name)
            }
        }
    }

    public func _mocksmithMarkVerified(sequence: UInt64) {
        markVerified([sequence])
    }

    public func matchesInvocation(sequence: UInt64) -> Bool {
        state.withLock { $0.invocations.sortedIndex(of: sequence) != nil }
    }

    public func verification(count: Count) -> VerificationResult {
        let snapshot = state.withLock { $0.invocations }
        let actual = snapshot.count
        let success = count.matches(actual)
        if success {
            markVerified(snapshot)
        }
        return .init(
            success: success,
            message: success ? "Verified \(count) for \(name)" : "Expected \(count) for \(name), got \(actual)"
        )
    }

    public func reset(_ scopes: [MockScope] = Array(MockScope.all)) {
        let scopes = Set(scopes)
        let retired = state.withLock { state in
            let retired = state.configuration
            if scopes.contains(.invocations) {
                state.invocations.removeAll()
                state.verifiedSequences.removeAll()
            }
            state.configuration.reset(scopes)
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    /// Records the invocation, runs the winning action, and returns the next outcome of the winning stub, if any.
    private func selectOutcome(
        for arguments: borrowing Arguments,
        ephemeral: borrowing Ephemeral
    ) -> TransientStubOutcome<Arguments, Ephemeral, Output>? {
        // Matchers, actions, and answers are user code that may reenter this member, so only
        // recording and snapshotting happen under the lock. Assigning the snapshot rather than returning
        // it from `withLock` avoids generic metadata lookups on every call.
        var snapshot: MockConfiguration<Arguments, Ephemeral, TransientStubOutcome<Arguments, Ephemeral, Output>>?
        state.withLock { state in
            state.invocations.append(nextMockInvocationSequence())
            snapshot = state.configuration
        }
        return snapshot?.select(for: arguments, ephemeral: ephemeral)?.next()
    }

    private func markVerified(_ sequences: [UInt64]) {
        state.withLock { state in
            state.verifiedSequences.formUnion(sequences.filter { state.invocations.sortedIndex(of: $0) != nil })
        }
    }
}
