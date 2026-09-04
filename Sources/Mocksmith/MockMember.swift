import Foundation

/// Thread-safe runtime channel that records invocations and selects matching actions and stubs.
public final class MockMember<Arguments, Ephemeral, Output>: @unchecked Sendable {
    private final class InvocationWaiter: @unchecked Sendable {
        var id: UInt64?
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    private struct Stub {
        let id: UInt64
        let matches: (Arguments) -> Bool
        let specificity: Int
        var outcomes: [StubOutcome<Arguments, Ephemeral, Output>]
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
        var actionEnabled = true
        var stubEnabled = true
    }

    private let lock = NSLock()
    private struct Invocation {
        let sequence: UInt64
        let arguments: Arguments
    }

    private var invocations: [Invocation] = []
    private var verifiedSequences: Set<UInt64> = []
    private var stubs: [Stub] = []
    private var actions: [Action] = []
    private var actionStubs: [ActionStub] = []
    private var nextOutcome: [UInt64: Int] = [:]
    private var nextID: UInt64 = 0
    private var invocationGeneration: UInt64 = 0
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
        let sequence = nextMockInvocationSequence()
        let (snapshot, waiters) = lock.withLock { () -> (([Action], [Stub], [ActionStub]), [CheckedContinuation<Void, any Error>]) in
            invocations.append(.init(sequence: sequence, arguments: arguments))
            invocationGeneration &+= 1
            return ((actions, stubs, actionStubs), drainInvocationWaiters())
        }
        waiters.forEach { $0.resume() }

        let matchingActionStubs = snapshot.2.filter { $0.matches(arguments) }
        let action = bestAction(in: snapshot.0, arguments: arguments)
        let actionStub = bestActionStub(in: matchingActionStubs, forAction: true)
        if let actionStub, action.map({ wins(actionStub.specificity, actionStub.id, over: $0.specificity, $0.id) }) ?? true {
            actionStub.body(arguments, ephemeral)
        } else {
            action?.body(arguments, ephemeral)
        }

        let stub = bestStub(in: snapshot.1, arguments: arguments)
        let actionStubOutcome = bestActionStub(in: matchingActionStubs, forAction: false)
        let selected: (id: UInt64, outcomes: [StubOutcome<Arguments, Ephemeral, Output>])? = if let actionStubOutcome,
                                                                                                stub
                                                                                                .map({ wins(actionStubOutcome.specificity, actionStubOutcome.id, over: $0.specificity, $0.id) }) ??
                                                                                                true {
            (actionStubOutcome.id, actionStubOutcome.outcomes)
        } else if let stub {
            (stub.id, stub.outcomes)
        } else {
            nil
        }
        guard let selected else {
            if let unstubbed {
                return unstubbed()
            }
            throw MockError.unstubbed(name)
        }
        let outcome = consumeOutcome(id: selected.id, outcomes: selected.outcomes)
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
        let sequence = nextMockInvocationSequence()
        let (snapshot, waiters) = lock.withLock { () -> (([Action], [Stub], [ActionStub]), [CheckedContinuation<Void, any Error>]) in
            invocations.append(.init(sequence: sequence, arguments: arguments))
            invocationGeneration &+= 1
            return ((actions, stubs, actionStubs), drainInvocationWaiters())
        }
        waiters.forEach { $0.resume() }

        let matchingActionStubs = snapshot.2.filter { $0.matches(arguments) }
        let action = bestAction(in: snapshot.0, arguments: arguments)
        let actionStub = bestActionStub(in: matchingActionStubs, forAction: true)
        if let actionStub, action.map({ wins(actionStub.specificity, actionStub.id, over: $0.specificity, $0.id) }) ?? true {
            actionStub.body(arguments, ephemeral)
        } else {
            action?.body(arguments, ephemeral)
        }

        let stub = bestStub(in: snapshot.1, arguments: arguments)
        let actionStubOutcome = bestActionStub(in: matchingActionStubs, forAction: false)
        let selected: (id: UInt64, outcomes: [StubOutcome<Arguments, Ephemeral, Output>])? = if let actionStubOutcome,
                                                                                                stub
                                                                                                .map({ wins(actionStubOutcome.specificity, actionStubOutcome.id, over: $0.specificity, $0.id) }) ??
                                                                                                true {
            (actionStubOutcome.id, actionStubOutcome.outcomes)
        } else if let stub {
            (stub.id, stub.outcomes)
        } else {
            nil
        }
        guard let selected else {
            if let unstubbed {
                return unstubbed()
            }
            throw MockError.unstubbed(name)
        }
        let outcome = consumeOutcome(id: selected.id, outcomes: selected.outcomes)
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
        let sequence = nextMockInvocationSequence()
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            invocations.append(.init(sequence: sequence, arguments: arguments))
            invocationGeneration &+= 1
            return drainInvocationWaiters()
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns a typed, observational history for invocations matching `matching`.
    public func callHistory(matching: @escaping (Arguments) -> Bool) -> CallHistory<Arguments> {
        CallHistory(
            member: name,
            snapshot: { [self] in
                let snapshot = callHistorySnapshot()
                return (snapshot.generation, snapshot.arguments.filter(matching))
            },
            waitForChange: { [self] generation in
                try await waitForInvocationChange(after: generation)
            }
        )
    }

    public func invocationCount(matching: @escaping (Arguments) -> Bool) -> Int {
        let snapshot = lock.withLock { invocations }
        return snapshot.reduce(into: 0) {
            if matching($1.arguments) {
                $0 += 1
            }
        }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocations.map { .init(sequence: $0.sequence, member: name) }
        }
    }

    public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        lock.withLock {
            invocations.compactMap {
                verifiedSequences.contains($0.sequence) ? nil : .init(sequence: $0.sequence, member: name)
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
        let invocation = lock.withLock { invocations.first { $0.sequence == sequence } }
        return invocation.map { matching($0.arguments) } ?? false
    }

    public func verification(matching: @escaping (Arguments) -> Bool, count: Count) -> VerificationResult {
        let snapshot = lock.withLock { invocations }
        let matchingSequences = snapshot.compactMap { matching($0.arguments) ? $0.sequence : nil }
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
            let retired = (invocations, stubs, actions, actionStubs)
            if scopes.contains(.invocations) {
                invocations.removeAll()
                verifiedSequences.removeAll()
                invocationGeneration &+= 1
            }
            if scopes.contains(.stubs) {
                stubs.removeAll()
                nextOutcome.removeAll()
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

    private func bestAction(in candidates: [Action], arguments: Arguments) -> Action? {
        candidates.reduce(nil) { winner, candidate in
            guard candidate.matches(arguments) else {
                return winner
            }
            guard let winner else {
                return candidate
            }
            return wins(candidate.specificity, candidate.id, over: winner.specificity, winner.id) ? candidate : winner
        }
    }

    private func bestStub(in candidates: [Stub], arguments: Arguments) -> Stub? {
        candidates.reduce(nil) { winner, candidate in
            guard candidate.matches(arguments) else {
                return winner
            }
            guard let winner else {
                return candidate
            }
            return wins(candidate.specificity, candidate.id, over: winner.specificity, winner.id) ? candidate : winner
        }
    }

    private func bestActionStub(in candidates: [ActionStub], forAction: Bool) -> ActionStub? {
        candidates.reduce(nil) { winner, candidate in
            guard forAction ? candidate.actionEnabled : candidate.stubEnabled else {
                return winner
            }
            guard let winner else {
                return candidate
            }
            return wins(candidate.specificity, candidate.id, over: winner.specificity, winner.id) ? candidate : winner
        }
    }

    private func wins(_ specificity: Int, _ id: UInt64, over otherSpecificity: Int, _ otherID: UInt64) -> Bool {
        specificity > otherSpecificity || (specificity == otherSpecificity && id > otherID)
    }

    private func consumeOutcome(
        id: UInt64,
        outcomes: [StubOutcome<Arguments, Ephemeral, Output>]
    ) -> StubOutcome<Arguments, Ephemeral, Output> {
        lock.withLock {
            let index = min(nextOutcome[id, default: 0], outcomes.count - 1)
            nextOutcome[id] = index + 1
            return outcomes[index]
        }
    }

    private func markVerified(_ sequences: [UInt64]) {
        lock.withLock {
            let currentSequences = Set(invocations.map(\.sequence))
            verifiedSequences.formUnion(sequences.filter(currentSequences.contains))
        }
    }

    private func callHistorySnapshot() -> (generation: UInt64, arguments: [Arguments]) {
        lock.withLock { (invocationGeneration, invocations.map(\.arguments)) }
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
        let continuations = invocationWaiters.values.compactMap(\.continuation)
        invocationWaiters.removeAll()
        return continuations
    }
}
