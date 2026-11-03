import Foundation

/// Thread-safe, count-only runtime channel for transient arguments and results.
public final class TransientMockMember<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable
>: @unchecked Sendable {
    /// Index of the next outcome a stub returns; mutated only while holding `lock`.
    private final class OutcomeCursor {
        var next = 0
    }

    private struct Stub {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        var outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
        let cursor = OutcomeCursor()
    }

    private struct Action {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let body: (borrowing Arguments, borrowing Ephemeral) -> Void
        let specificity: Int
    }

    private struct ActionStub {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        let outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
        let body: (borrowing Arguments, borrowing Ephemeral) -> Void
        let cursor = OutcomeCursor()
        var actionEnabled = true
        var stubEnabled = true
    }

    private let lock = NSLock()
    private var invocations: [UInt64] = []
    private var recordedSequences: Set<UInt64> = []
    private var verifiedSequences: Set<UInt64> = []
    private var stubs: [Stub] = []
    private var actions: [Action] = []
    private var actionStubs: [ActionStub] = []
    private var nextID: UInt64 = 0
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
        let id = lock.withLock {
            nextID += 1
            stubs.append(Stub(id: nextID, matches: matching, specificity: specificity, outcomes: outcomes))
            return nextID
        }
        return _MocksmithTransientStubRegistration { [self] outcomes in
            lock.withLock {
                guard let index = stubs.firstIndex(where: { $0.id == id }) else {
                    preconditionFailure("Mock stub registration is no longer active")
                }
                stubs[index].outcomes.append(contentsOf: outcomes)
            }
        }
    }

    public func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        lock.withLock {
            nextID += 1
            actions.append(Action(id: nextID, matches: matching, body: action, specificity: specificity))
        }
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
        lock.withLock {
            nextID += 1
            actionStubs.append(
                ActionStub(
                    id: nextID,
                    matches: matching,
                    specificity: specificity,
                    outcomes: outcomes,
                    body: action
                )
            )
        }
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
        lock.withLock { recordedSequences.contains(sequence) }
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
            let retired = (stubs, actions, actionStubs)
            if scopes.contains(.invocations) {
                invocations.removeAll()
                recordedSequences.removeAll()
                verifiedSequences.removeAll()
            }
            if scopes.contains(.stubs) {
                stubs.removeAll()
                for index in actionStubs.indices {
                    actionStubs[index].stubEnabled = false
                }
            }
            if scopes.contains(.actions) {
                actions.removeAll()
                for index in actionStubs.indices {
                    actionStubs[index].actionEnabled = false
                }
            }
            actionStubs.removeAll { !$0.actionEnabled && !$0.stubEnabled }
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
        let actions = actions
        let stubs = stubs
        let actionStubs = actionStubs
        lock.unlock()

        // Winners are tracked by index so non-matching candidates are never copied out of the
        // arrays. Each coupled matcher runs once and decides both its action and its stub side.
        var actionStubAction: Int?
        var actionStubOutcome: Int?
        for index in 0 ..< actionStubs.count where actionStubs[index].matches(arguments) {
            if actionStubs[index].actionEnabled, actionStubAction.map({ wins(actionStubs[index].specificity, actionStubs[index].id, over: actionStubs[$0].specificity, actionStubs[$0].id) }) ?? true {
                actionStubAction = index
            }
            if actionStubs[index].stubEnabled, actionStubOutcome.map({ wins(actionStubs[index].specificity, actionStubs[index].id, over: actionStubs[$0].specificity, actionStubs[$0].id) }) ?? true {
                actionStubOutcome = index
            }
        }

        var action: Int?
        for index in 0 ..< actions.count where actions[index].matches(arguments) {
            if action.map({ wins(actions[index].specificity, actions[index].id, over: actions[$0].specificity, actions[$0].id) }) ?? true {
                action = index
            }
        }
        if let actionStubAction, action.map({ wins(actionStubs[actionStubAction].specificity, actionStubs[actionStubAction].id, over: actions[$0].specificity, actions[$0].id) }) ?? true {
            actionStubs[actionStubAction].body(arguments, ephemeral)
        } else if let action {
            actions[action].body(arguments, ephemeral)
        }

        var stub: Int?
        for index in 0 ..< stubs.count where stubs[index].matches(arguments) {
            if stub.map({ wins(stubs[index].specificity, stubs[index].id, over: stubs[$0].specificity, stubs[$0].id) }) ?? true {
                stub = index
            }
        }
        if let actionStubOutcome, stub.map({ wins(actionStubs[actionStubOutcome].specificity, actionStubs[actionStubOutcome].id, over: stubs[$0].specificity, stubs[$0].id) }) ?? true {
            return consumeOutcome(actionStubs[actionStubOutcome].outcomes, cursor: actionStubs[actionStubOutcome].cursor)
        }
        if let stub {
            return consumeOutcome(stubs[stub].outcomes, cursor: stubs[stub].cursor)
        }
        return nil
    }

    private func wins(_ specificity: Int, _ id: UInt64, over otherSpecificity: Int, _ otherID: UInt64) -> Bool {
        specificity > otherSpecificity || (specificity == otherSpecificity && id > otherID)
    }

    private func consumeOutcome(
        _ outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>],
        cursor: OutcomeCursor
    ) -> TransientStubOutcome<Arguments, Ephemeral, Output> {
        lock.lock()
        let index = min(cursor.next, outcomes.count - 1)
        cursor.next = index + 1
        lock.unlock()
        return outcomes[index]
    }

    /// Must be called while holding `lock`. Assigning the sequence under the member lock keeps
    /// `invocations` sorted by sequence.
    private func recordInvocation() {
        let sequence = nextMockInvocationSequence()
        recordedSequences.insert(sequence)
        invocations.append(sequence)
    }

    private func markVerified(_ sequences: [UInt64]) {
        lock.withLock {
            verifiedSequences.formUnion(sequences.filter(recordedSequences.contains))
        }
    }
}
