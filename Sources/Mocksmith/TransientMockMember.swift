import Foundation

/// Thread-safe, count-only runtime channel for transient arguments and results.
public final class TransientMockMember<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable
>: @unchecked Sendable {
    private struct Stub {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        var outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
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
        var actionEnabled = true
        var stubEnabled = true
    }

    private let lock = NSLock()
    private var invocations: [UInt64] = []
    private var verifiedSequences: Set<UInt64> = []
    private var stubs: [Stub] = []
    private var actions: [Action] = []
    private var actionStubs: [ActionStub] = []
    private var nextOutcome: [UInt64: Int] = [:]
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
        let sequence = nextMockInvocationSequence()
        let snapshot = lock.withLock { () -> ([Action], [Stub], [ActionStub]) in
            invocations.append(sequence)
            return (actions, stubs, actionStubs)
        }

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
        let selected: (id: UInt64, outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>])? = if let actionStubOutcome, stub.map({ wins(
            actionStubOutcome.specificity,
            actionStubOutcome.id,
            over: $0.specificity,
            $0.id
        ) }) ?? true {
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
        switch consumeOutcome(id: selected.id, outcomes: selected.outcomes) {
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
        let sequence = nextMockInvocationSequence()
        let snapshot = lock.withLock { () -> ([Action], [Stub], [ActionStub]) in
            invocations.append(sequence)
            return (actions, stubs, actionStubs)
        }

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
        let selected: (
            id: UInt64,
            outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
        )? = if let actionStubOutcome, stub.map({ wins(
            actionStubOutcome.specificity,
            actionStubOutcome.id,
            over: $0.specificity,
            $0.id
        ) }) ?? true {
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
        switch consumeOutcome(id: selected.id, outcomes: selected.outcomes) {
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
        let sequence = nextMockInvocationSequence()
        lock.withLock { invocations.append(sequence) }
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
        lock.withLock { invocations.contains(sequence) }
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
                verifiedSequences.removeAll()
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
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    private func bestAction(in candidates: [Action], arguments: borrowing Arguments) -> Action? {
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

    private func bestStub(in candidates: [Stub], arguments: borrowing Arguments) -> Stub? {
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
        outcomes: [TransientStubOutcome<Arguments, Ephemeral, Output>]
    ) -> TransientStubOutcome<Arguments, Ephemeral, Output> {
        lock.withLock {
            let index = min(nextOutcome[id, default: 0], outcomes.count - 1)
            nextOutcome[id] = index + 1
            return outcomes[index]
        }
    }

    private func markVerified(_ sequences: [UInt64]) {
        lock.withLock {
            let currentSequences = Set(invocations)
            verifiedSequences.formUnion(sequences.filter(currentSequences.contains))
        }
    }
}
