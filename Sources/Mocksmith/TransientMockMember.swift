import Foundation

/// Thread-safe, count-only runtime channel for transient arguments and results.
public final class TransientMockMember<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable
>: @unchecked Sendable {
    private let lock = NSLock()
    /// Recorded sequences in ascending order; they are assigned under `lock`.
    private var invocations: [UInt64] = []
    private var verifiedSequences: Set<UInt64> = []
    private var configuration = MockConfiguration<Arguments, Ephemeral, TransientStubOutcome<Arguments, Ephemeral, Output>>()
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
        let id = lock.withLock { configuration.addStub(matching: matching, specificity: specificity, outcomes: outcomes) }
        return _MocksmithTransientStubRegistration { [self] outcomes in
            lock.withLock { configuration.appendOutcomes(outcomes, toStub: id) }
        }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        lock.withLock { configuration.addAction(matching: matching, specificity: specificity, body: action) }
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
        lock.withLock { configuration.addAction(matching: matching, specificity: specificity, outcomes: outcomes, body: action) }
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
        lock.withLock { recordInvocation() }
    }

    public var invocationCount: Int {
        lock.withLock { invocations.count }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocations.map { .init(sequence: $0, member: name) }
        }
    }

    public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocations.compactMap {
                verifiedSequences.contains($0) ? nil : .init(sequence: $0, member: name)
            }
        }
    }

    public func _mocksmithMarkVerified(sequence: UInt64) {
        markVerified([sequence])
    }

    public func matchesInvocation(sequence: UInt64) -> Bool {
        lock.withLock { invocations.sortedIndex(of: sequence) != nil }
    }

    public func verification(count: Count) -> VerificationResult {
        let snapshot = lock.withLock { invocations }
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
        let retired = lock.withLock {
            let retired = configuration
            if scopes.contains(.invocations) {
                invocations.removeAll()
                verifiedSequences.removeAll()
            }
            configuration.reset(scopes)
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
        // recording and snapshotting happen under the lock. Nothing in this section can throw.
        lock.lock()
        recordInvocation()
        let configuration = configuration
        lock.unlock()
        return configuration.select(for: arguments, ephemeral: ephemeral)?.next(guardedBy: lock)
    }

    /// Must be called while holding `lock`. Assigning the sequence under the member lock keeps
    /// `invocations` sorted by sequence.
    private func recordInvocation() {
        let sequence = nextMockInvocationSequence()
        invocations.append(sequence)
    }

    private func markVerified(_ sequences: [UInt64]) {
        lock.withLock {
            verifiedSequences.formUnion(sequences.filter { invocations.sortedIndex(of: $0) != nil })
        }
    }
}
