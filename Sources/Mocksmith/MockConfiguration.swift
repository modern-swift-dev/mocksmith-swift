import Foundation
import Synchronization

/// The stubs, actions, and coupled action stubs of one mock member, and how an invocation picks among them.
///
/// Not thread-safe. Members mutate it while holding their lock and select from a copy taken under that
/// lock, so matchers, actions, and the release of retired closures run outside the lock.
struct MockConfiguration<Arguments: ~Copyable, Ephemeral: ~Copyable, Outcome> {
    /// Index of the next outcome a stub returns, shared by every configuration snapshot of the stub.
    final class OutcomeCursor {
        let next = Atomic<Int>(0)
    }

    /// The outcomes of a winning stub and its position in them.
    struct Selection {
        let outcomes: [Outcome]
        let cursor: OutcomeCursor

        /// Returns the next outcome, repeating the last one once all were returned. Lock-free: concurrent
        /// callers each claim a distinct index, and the cursor stops at `outcomes.count` so outcomes
        /// appended later are still returned in order.
        func next() -> Outcome {
            var index = cursor.next.load(ordering: .relaxed)
            while index < outcomes.count {
                let (claimed, current) = cursor.next.compareExchange(expected: index, desired: index + 1, ordering: .relaxed)
                if claimed {
                    return outcomes[index]
                }
                index = current
            }
            return outcomes[outcomes.count - 1]
        }
    }

    private struct Stub {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        var outcomes: [Outcome]
        let cursor = OutcomeCursor()
    }

    private struct Action {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        let body: (borrowing Arguments, borrowing Ephemeral) -> Void
    }

    private struct ActionStub {
        let id: UInt64
        let matches: (borrowing Arguments) -> Bool
        let specificity: Int
        let outcomes: [Outcome]
        let body: (borrowing Arguments, borrowing Ephemeral) -> Void
        let cursor = OutcomeCursor()
        var actionEnabled = true
        var stubEnabled = true
    }

    private var stubs: [Stub] = []
    private var actions: [Action] = []
    private var actionStubs: [ActionStub] = []
    private var nextID: UInt64 = 0

    /// Adds a stub and returns its identifier for `appendOutcomes(_:toStub:)`.
    mutating func addStub(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int,
        outcomes: [Outcome]
    ) -> UInt64 {
        nextID += 1
        stubs.append(Stub(id: nextID, matches: matching, specificity: specificity, outcomes: outcomes))
        return nextID
    }

    mutating func appendOutcomes(_ outcomes: [Outcome], toStub id: UInt64) {
        guard let index = stubs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Mock stub registration is no longer active")
        }
        stubs[index].outcomes.append(contentsOf: outcomes)
    }

    mutating func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int,
        body: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        nextID += 1
        actions.append(Action(id: nextID, matches: matching, specificity: specificity, body: body))
    }

    /// Adds an action and a stub that share one matcher, evaluated once per invocation.
    mutating func addAction(
        matching: @escaping (borrowing Arguments) -> Bool,
        specificity: Int,
        outcomes: [Outcome],
        body: @escaping (borrowing Arguments, borrowing Ephemeral) -> Void
    ) {
        nextID += 1
        actionStubs.append(ActionStub(id: nextID, matches: matching, specificity: specificity, outcomes: outcomes, body: body))
    }

    /// Removes stubs and/or actions; coupled action stubs keep whichever side was not reset.
    mutating func reset(_ scopes: Set<MockScope>) {
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
    }

    /// Runs the winning action and returns the winning stub's outcomes, if any. Call outside the member lock.
    func select(for arguments: borrowing Arguments, ephemeral: borrowing Ephemeral) -> Selection? {
        // Winners are tracked by index so non-matching candidates are never copied out of the
        // arrays. Each coupled matcher runs once and decides both its action and its stub side.
        var actionStubAction: Int?
        var actionStubOutcome: Int?
        for index in 0 ..< actionStubs.count where actionStubs[index].matches(arguments) {
            let candidate = (actionStubs[index].specificity, actionStubs[index].id)
            if actionStubs[index].actionEnabled, actionStubAction.map({ wins(candidate, over: (actionStubs[$0].specificity, actionStubs[$0].id)) }) ?? true {
                actionStubAction = index
            }
            if actionStubs[index].stubEnabled, actionStubOutcome.map({ wins(candidate, over: (actionStubs[$0].specificity, actionStubs[$0].id)) }) ?? true {
                actionStubOutcome = index
            }
        }

        var action: Int?
        for index in 0 ..< actions.count where actions[index].matches(arguments) {
            if action.map({ wins((actions[index].specificity, actions[index].id), over: (actions[$0].specificity, actions[$0].id)) }) ?? true {
                action = index
            }
        }
        if let actionStubAction,
           action.map({ wins((actionStubs[actionStubAction].specificity, actionStubs[actionStubAction].id), over: (actions[$0].specificity, actions[$0].id)) }) ?? true {
            actionStubs[actionStubAction].body(arguments, ephemeral)
        } else if let action {
            actions[action].body(arguments, ephemeral)
        }

        var stub: Int?
        for index in 0 ..< stubs.count where stubs[index].matches(arguments) {
            if stub.map({ wins((stubs[index].specificity, stubs[index].id), over: (stubs[$0].specificity, stubs[$0].id)) }) ?? true {
                stub = index
            }
        }
        if let actionStubOutcome,
           stub.map({ wins((actionStubs[actionStubOutcome].specificity, actionStubs[actionStubOutcome].id), over: (stubs[$0].specificity, stubs[$0].id)) }) ?? true {
            return Selection(outcomes: actionStubs[actionStubOutcome].outcomes, cursor: actionStubs[actionStubOutcome].cursor)
        }
        if let stub {
            return Selection(outcomes: stubs[stub].outcomes, cursor: stubs[stub].cursor)
        }
        return nil
    }
}

/// Whether a candidate `(specificity, id)` beats the current winner: more specific first, then newer.
private func wins(_ candidate: (specificity: Int, id: UInt64), over winner: (specificity: Int, id: UInt64)) -> Bool {
    candidate.specificity > winner.specificity || (candidate.specificity == winner.specificity && candidate.id > winner.id)
}
