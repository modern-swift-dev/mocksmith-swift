import Foundation
import Synchronization

/// Thread-safe runtime channel that records invocations and selects matching actions and stubs.
public final class MockMember<Arguments, Ephemeral, Output>: Sendable {
    private struct State {
        /// Recorded invocations as parallel arrays; sequences ascend because they are assigned under the lock.
        var invocationSequences: [UInt64] = []
        // Sound: the mutex guards every access; recording arguments on the invoking thread for the test
        // that reads them is the mock's documented contract, so region checking is waived for them.
        nonisolated(unsafe) var invocationArguments: [Arguments] = []
        var verifiedSequences: Set<UInt64> = []
        // Sound: the mutex guards every access; user matchers, actions, and outcomes are registered on
        // one thread and run on invoking threads, which is the mock's documented contract.
        nonisolated(unsafe) var configuration = MockConfiguration<Arguments, Ephemeral, StubOutcome<Arguments, Ephemeral, Output>>()
        var invocationGeneration: UInt64 = 0
        var invocationResets: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var invocationWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())
    private let name: String

    public init(name: String = "member") {
        self.name = name
    }

    @discardableResult public func addStub(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [StubOutcome<Arguments, Ephemeral, Output>]
    ) -> _MocksmithStubRegistration<Arguments, Ephemeral, Output> {
        precondition(!outcomes.isEmpty, "Mock stubs need at least one outcome")
        let id = state.withLock { $0.configuration.addStub(matching: matching, specificity: specificity, outcomes: outcomes) }
        return _MocksmithStubRegistration { [self] outcomes in
            state.withLock { $0.configuration.appendOutcomes(outcomes, toStub: id) }
        }
    }

    public func addAction(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (Arguments, borrowing Ephemeral) -> Void
    ) {
        state.withLock { $0.configuration.addAction(matching: matching, specificity: specificity, body: action) }
    }

    public func addAction(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (Arguments) -> Void
    ) where Ephemeral == Void {
        addAction(matching: matching, specificity: specificity) { arguments, _ in
            action(arguments)
        }
    }

    public func addAction(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [StubOutcome<Arguments, Ephemeral, Output>],
        action: @escaping (Arguments, borrowing Ephemeral) -> Void
    ) {
        precondition(!outcomes.isEmpty, "Mock stubs need at least one outcome")
        state.withLock { $0.configuration.addAction(matching: matching, specificity: specificity, outcomes: outcomes, body: action) }
    }

    public func addAction(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        outcomes: [StubOutcome<Arguments, Ephemeral, Output>],
        action: @escaping (Arguments) -> Void
    ) where Ephemeral == Void {
        addAction(matching: matching, specificity: specificity, outcomes: outcomes) { arguments, _ in
            action(arguments)
        }
    }

    public func invoke(_ arguments: Arguments, ephemeral: borrowing Ephemeral, unstubbed: (() -> Output)? = nil) throws -> Output {
        guard let outcome = selectOutcome(for: arguments, ephemeral: ephemeral) else {
            if let unstubbed {
                return unstubbed()
            }
            throw MockError.unstubbed(name)
        }
        switch outcome {
            case let .returnValue(value): return value
            case let .throwError(error): throw error
            case let .answer(answer): return try answer(arguments, ephemeral)
            case .asyncAnswer:
                preconditionFailure("Async mock answer requires async invocation")
        }
    }

    public func invoke(_ arguments: Arguments) throws -> Output where Ephemeral == Void {
        try invoke(arguments, ephemeral: ())
    }

    public func invoke(_ arguments: Arguments, unstubbed: (() -> Output)?) throws -> Output where Ephemeral == Void {
        try invoke(arguments, ephemeral: (), unstubbed: unstubbed)
    }

    public func invokeAsync(
        _ arguments: Arguments,
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
            case let .returnValue(value): return value
            case let .throwError(error): throw error
            case let .answer(answer): return try answer(arguments, ephemeral)
            case let .asyncAnswer(answer): return try await answer(arguments)
        }
    }

    public func invokeAsync(_ arguments: Arguments) async throws -> Output where Ephemeral == Void {
        try await invokeAsync(arguments, ephemeral: ())
    }

    public func invokeAsync(
        _ arguments: Arguments,
        unstubbed: (@Sendable () -> Output)?
    ) async throws -> Output where Ephemeral == Void {
        try await invokeAsync(arguments, ephemeral: (), unstubbed: unstubbed)
    }

    public func record(_ arguments: Arguments) {
        let waiters = state.withLock { recordInvocation(arguments, in: &$0) }
        waiters.forEach { $0.resume() }
    }

    /// Returns a typed, observational history for invocations matching `matching`.
    public func callHistory(matching: @escaping (Arguments) -> Bool) -> CallHistory<Arguments> {
        CallHistory(
            member: name,
            snapshot: { [self] in
                // Assigned rather than returned from `withLock`, which would look up generic metadata.
                var snapshot = CallHistorySnapshot<Arguments>(generation: 0, resets: 0, arguments: [])
                state.withLock {
                    snapshot = CallHistorySnapshot(generation: $0.invocationGeneration, resets: $0.invocationResets, arguments: $0.invocationArguments)
                }
                return snapshot
            },
            matching: matching,
            waitForChange: { [self] generation in
                try await waitForInvocationChange(after: generation)
            }
        )
    }

    public func invocationCount(matching: @escaping (Arguments) -> Bool) -> Int {
        let snapshot = state.withLock { $0.invocationArguments }
        return snapshot.reduce(into: 0) {
            if matching($1) {
                $0 += 1
            }
        }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        state.withLock { state in
            state.invocationSequences.map { .init(sequence: $0, member: name) }
        }
    }

    public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        state.withLock { state in
            state.invocationSequences.compactMap {
                state.verifiedSequences.contains($0) ? nil : .init(sequence: $0, member: name)
            }
        }
    }

    public func _mocksmithMarkVerified(sequence: UInt64) {
        markVerified([sequence])
    }

    public func matchesInvocation(
        sequence: UInt64,
        matching: @escaping (Arguments) -> Bool
    ) -> Bool {
        let arguments = state.withLock { state in state.invocationSequences.sortedIndex(of: sequence).map { state.invocationArguments[$0] } }
        return arguments.map(matching) ?? false
    }

    public func verification(matching: @escaping (Arguments) -> Bool, count: Count) -> VerificationResult {
        let (sequences, arguments) = state.withLock { ($0.invocationSequences, $0.invocationArguments) }
        let matchingSequences = zip(sequences, arguments).compactMap { matching($1) ? $0 : nil }
        let actual = matchingSequences.count
        let success = count.matches(actual)
        if success {
            markVerified(matchingSequences)
        }
        return .init(
            success: success,
            message: success ? "Verified \(count) for \(name)" : "Expected \(count) for \(name), got \(actual)"
        )
    }

    public func reset(_ scopes: [MockScope] = Array(MockScope.all)) {
        let scopes = Set(scopes)
        let (retired, waiters) = state.withLock { state in
            // User values and captured objects may reenter this member from deinit.
            let retired = (state.invocationArguments, state.configuration)
            if scopes.contains(.invocations) {
                state.invocationSequences.removeAll()
                state.invocationArguments.removeAll()
                state.verifiedSequences.removeAll()
                state.invocationGeneration &+= 1
                state.invocationResets &+= 1
            }
            state.configuration.reset(scopes)
            return (retired, scopes.contains(.invocations) ? drainInvocationWaiters(in: &state) : [])
        }
        withExtendedLifetime(retired) {}
        waiters.forEach { $0.resume() }
    }

    /// Records the invocation, runs the winning action, and returns the next outcome of the winning stub, if any.
    private func selectOutcome(for arguments: Arguments, ephemeral: borrowing Ephemeral) -> StubOutcome<Arguments, Ephemeral, Output>? {
        // Matchers, actions, and answers are user code that may reenter this member, so only
        // recording and snapshotting happen under the lock. Assigning the snapshot rather than returning
        // it from `withLock` avoids generic metadata lookups on every call.
        var snapshot: MockConfiguration<Arguments, Ephemeral, StubOutcome<Arguments, Ephemeral, Output>>?
        let waiters = state.withLock { state in
            snapshot = state.configuration
            return recordInvocation(arguments, in: &state)
        }
        waiters.forEach { $0.resume() }
        return snapshot?.select(for: arguments, ephemeral: ephemeral)?.next()
    }

    private func markVerified(_ sequences: [UInt64]) {
        state.withLock { state in
            state.verifiedSequences.formUnion(sequences.filter { state.invocationSequences.sortedIndex(of: $0) != nil })
        }
    }

    /// Assigning the sequence under the member lock keeps `invocationSequences` sorted. Returns the
    /// waiters to resume once the lock is released. An instance method rather than a `State` method,
    /// because calling a method of the generic `State` looks up its metadata on every invocation.
    private func recordInvocation(_ arguments: Arguments, in state: inout State) -> [CheckedContinuation<Void, any Error>] {
        let sequence = nextMockInvocationSequence()
        state.invocationSequences.append(sequence)
        state.invocationArguments.append(arguments)
        state.invocationGeneration &+= 1
        return drainInvocationWaiters(in: &state)
    }

    private func drainInvocationWaiters(in state: inout State) -> [CheckedContinuation<Void, any Error>] {
        // Called on every invocation; skip the generic collection work when nobody waits.
        guard !state.invocationWaiters.isEmpty else {
            return []
        }
        let continuations = Array(state.invocationWaiters.values)
        state.invocationWaiters.removeAll()
        return continuations
    }

    private func waitForInvocationChange(after generation: UInt64) async throws {
        let id = state.withLock { state in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    // Cancellation is flagged before `onCancel` runs, and both sides check under the
                    // lock, so a cancelled waiter is either never registered or removed by `onCancel`.
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard state.invocationGeneration == generation else {
                        return .success(())
                    }
                    state.invocationWaiters[id] = continuation
                    return nil
                }
                switch immediate {
                    case .success?: continuation.resume()
                    case let .failure(error)?: continuation.resume(throwing: error)
                    case nil: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { $0.invocationWaiters.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

extension [UInt64] {
    /// The index of `value` in this ascending array, found by binary search.
    func sortedIndex(of value: UInt64) -> Int? {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if self[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < endIndex && self[low] == value ? low : nil
    }
}
