import Foundation

/// Thread-safe runtime channel that records invocations and selects matching actions and stubs.
public final class MockMember<Arguments, Ephemeral, Output>: @unchecked Sendable {
    private final class InvocationWaiter: @unchecked Sendable {
        var id: UInt64?
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    /// Index of the next outcome a stub returns; mutated only while holding `lock`.
    private final class OutcomeCursor {
        var next = 0
    }

    private struct Stub {
        let id: UInt64
        let matches: (Arguments) -> Bool
        let specificity: Int
        var outcomes: [StubOutcome<Arguments, Ephemeral, Output>]
        let cursor = OutcomeCursor()
    }

    private struct Action {
        let id: UInt64
        let matches: (Arguments) -> Bool
        let specificity: Int
        let body: (Arguments, borrowing Ephemeral) -> Void
    }

    private struct ActionStub {
        let id: UInt64
        let matches: (Arguments) -> Bool
        let specificity: Int
        let outcomes: [StubOutcome<Arguments, Ephemeral, Output>]
        let body: (Arguments, borrowing Ephemeral) -> Void
        let cursor = OutcomeCursor()
        var actionEnabled = true
        var stubEnabled = true
    }

    private let lock = NSLock()
    /// Recorded invocations as parallel arrays; sequences ascend because they are assigned under `lock`.
    private var invocationSequences: [UInt64] = []
    private var invocationArguments: [Arguments] = []
    private var verifiedSequences: Set<UInt64> = []
    private var stubs: [Stub] = []
    private var actions: [Action] = []
    private var actionStubs: [ActionStub] = []
    private var nextID: UInt64 = 0
    private var invocationGeneration: UInt64 = 0
    private var invocationResets: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var invocationWaiters: [UInt64: InvocationWaiter] = [:]
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
        let id = lock.withLock {
            nextID += 1
            stubs.append(Stub(id: nextID, matches: matching, specificity: specificity, outcomes: outcomes))
            return nextID
        }
        return _MocksmithStubRegistration { [self] outcomes in
            lock.withLock {
                guard let index = stubs.firstIndex(where: { $0.id == id }) else {
                    preconditionFailure("Mock stub registration is no longer active")
                }
                stubs[index].outcomes.append(contentsOf: outcomes)
            }
        }
    }

    public func addAction(
        matching: @escaping (Arguments) -> Bool,
        specificity: Int = 0,
        action: @escaping (Arguments, borrowing Ephemeral) -> Void
    ) {
        lock.withLock {
            nextID += 1
            actions.append(Action(id: nextID, matches: matching, specificity: specificity, body: action))
        }
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
        lock.lock()
        let waiters = recordInvocation(arguments)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    /// Returns a typed, observational history for invocations matching `matching`.
    public func callHistory(matching: @escaping (Arguments) -> Bool) -> CallHistory<Arguments> {
        CallHistory(
            member: name,
            snapshot: { [self] in
                lock.withLock {
                    CallHistorySnapshot(generation: invocationGeneration, resets: invocationResets, arguments: invocationArguments)
                }
            },
            matching: matching,
            waitForChange: { [self] generation in
                try await waitForInvocationChange(after: generation)
            }
        )
    }

    public func invocationCount(matching: @escaping (Arguments) -> Bool) -> Int {
        let snapshot = lock.withLock { invocationArguments }
        return snapshot.reduce(into: 0) {
            if matching($1) {
                $0 += 1
            }
        }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocationSequences.map { .init(sequence: $0, member: name) }
        }
    }

    public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocationSequences.compactMap {
                verifiedSequences.contains($0) ? nil : .init(sequence: $0, member: name)
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
        let arguments = lock.withLock { invocationSequences.sortedIndex(of: sequence).map { invocationArguments[$0] } }
        return arguments.map(matching) ?? false
    }

    public func verification(matching: @escaping (Arguments) -> Bool, count: Count) -> VerificationResult {
        let (sequences, arguments) = lock.withLock { (invocationSequences, invocationArguments) }
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
        let (retired, waiters) = lock.withLock {
            // User values and captured objects may reenter this member from deinit.
            let retired = (invocationArguments, stubs, actions, actionStubs)
            if scopes.contains(.invocations) {
                invocationSequences.removeAll()
                invocationArguments.removeAll()
                verifiedSequences.removeAll()
                invocationGeneration &+= 1
                invocationResets &+= 1
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
            return (retired, scopes.contains(.invocations) ? drainInvocationWaiters() : [])
        }
        withExtendedLifetime(retired) {}
        waiters.forEach { $0.resume() }
    }

    /// Records the invocation, runs the winning action, and returns the next outcome of the winning stub, if any.
    private func selectOutcome(for arguments: Arguments, ephemeral: borrowing Ephemeral) -> StubOutcome<Arguments, Ephemeral, Output>? {
        // Matchers, actions, and answers are user code that may reenter this member, so only
        // recording and snapshotting happen under the lock. Nothing in this section can throw.
        lock.lock()
        let waiters = recordInvocation(arguments)
        let actions = actions
        let stubs = stubs
        let actionStubs = actionStubs
        lock.unlock()
        waiters.forEach { $0.resume() }

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
        _ outcomes: [StubOutcome<Arguments, Ephemeral, Output>],
        cursor: OutcomeCursor
    ) -> StubOutcome<Arguments, Ephemeral, Output> {
        lock.lock()
        let index = min(cursor.next, outcomes.count - 1)
        cursor.next = index + 1
        lock.unlock()
        return outcomes[index]
    }

    private func markVerified(_ sequences: [UInt64]) {
        lock.withLock {
            verifiedSequences.formUnion(sequences.filter { invocationSequences.sortedIndex(of: $0) != nil })
        }
    }

    /// Must be called while holding `lock`. Assigning the sequence under the member lock keeps
    /// `invocationSequences` sorted. Returns the waiters to resume once the lock is released.
    private func recordInvocation(_ arguments: Arguments) -> [CheckedContinuation<Void, any Error>] {
        let sequence = nextMockInvocationSequence()
        invocationSequences.append(sequence)
        invocationArguments.append(arguments)
        invocationGeneration &+= 1
        return drainInvocationWaiters()
    }

    private func waitForInvocationChange(after generation: UInt64) async throws {
        let waiter = InvocationWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if waiter.cancelled {
                        return .failure(CancellationError())
                    }
                    guard invocationGeneration == generation else {
                        return .success(())
                    }
                    nextWaiterID &+= 1
                    waiter.id = nextWaiterID
                    waiter.continuation = continuation
                    invocationWaiters[nextWaiterID] = waiter
                    return nil
                }
                switch immediate {
                    case .success?: continuation.resume()
                    case let .failure(error)?: continuation.resume(throwing: error)
                    case nil: break
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                waiter.cancelled = true
                guard let id = waiter.id, invocationWaiters.removeValue(forKey: id) != nil else {
                    return nil
                }
                return waiter.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func drainInvocationWaiters() -> [CheckedContinuation<Void, any Error>] {
        // Called on every invocation; skip the generic collection work when nobody waits.
        guard !invocationWaiters.isEmpty else {
            return []
        }
        let continuations = invocationWaiters.values.compactMap(\.continuation)
        invocationWaiters.removeAll()
        return continuations
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
