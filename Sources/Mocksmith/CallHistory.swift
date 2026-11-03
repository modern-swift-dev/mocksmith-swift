import Foundation

/// Errors thrown while waiting for recorded mock calls.
public enum MockWaitError: Error, Sendable, Equatable {
    case timedOut(member: String, expectedCount: Int, actualCount: Int)
}

/// Errors thrown while reading a call history with an invalid cardinality.
public enum CallHistoryError: Error, Sendable, Equatable {
    case expectedExactlyOne(member: String, actualCount: Int)
    case expectedAtLeastOne(member: String)
}

/// The recorded arguments of one channel at one point in time.
struct CallHistorySnapshot<Arguments> {
    /// Changes whenever an invocation is recorded or invocations are reset.
    let generation: UInt64
    /// Changes whenever invocations are reset; between resets `arguments` only grows.
    let resets: UInt64
    /// Every recorded argument in invocation order, before matching.
    let arguments: [Arguments]
}

/// A typed, observational view of invocations recorded by one mock member.
public struct CallHistory<Arguments>: Sendable {
    private enum WaitResult: Sendable {
        case changed
        case timedOut
    }

    private let member: String
    private let snapshot: @Sendable () -> CallHistorySnapshot<Arguments>
    // Sound: like every mock matcher, this one may run on whichever thread uses the mock; the mock's
    // documented contract leaves its thread safety to the test that supplies it.
    private nonisolated(unsafe) let matching: (Arguments) -> Bool
    private let waitForChange: @Sendable (UInt64) async throws -> Void

    package var _mocksmithMemberName: String {
        member
    }

    init(
        member: String,
        snapshot: @escaping @Sendable () -> CallHistorySnapshot<Arguments>,
        matching: @escaping (Arguments) -> Bool,
        waitForChange: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.member = member
        self.snapshot = snapshot
        self.matching = matching
        self.waitForChange = waitForChange
    }

    /// The matching arguments in invocation order.
    public var arguments: [Arguments] {
        snapshot().arguments.filter(matching)
    }

    /// The number of matching invocations.
    public var count: Int {
        matchingCount(in: snapshot().arguments[...])
    }

    /// The first matching argument, if a call was recorded.
    public var firstArgument: Arguments? {
        snapshot().arguments.first(where: matching)
    }

    /// The last matching argument, if a call was recorded.
    public var lastArgument: Arguments? {
        snapshot().arguments.last(where: matching)
    }

    /// The matching argument at `index`, or `nil` when the index is out of bounds.
    public func argument(at index: Int) -> Arguments? {
        guard index >= 0 else {
            return nil
        }
        var remaining = index
        for argument in snapshot().arguments where matching(argument) {
            if remaining == 0 {
                return argument
            }
            remaining -= 1
        }
        return nil
    }

    /// The sole matching argument, or an error unless exactly one call was recorded.
    public var onlyArgument: Arguments {
        get throws {
            let arguments = snapshot().arguments
            guard let first = arguments.firstIndex(where: matching) else {
                throw CallHistoryError.expectedExactlyOne(member: member, actualCount: 0)
            }
            let rest = arguments[(first + 1)...]
            guard !rest.contains(where: matching) else {
                throw CallHistoryError.expectedExactlyOne(member: member, actualCount: 1 + matchingCount(in: rest))
            }
            return arguments[first]
        }
    }

    /// Waits until at least `count` matching calls have been recorded.
    public func waitForCount(_ count: Int, timeout: Duration) async throws {
        precondition(count >= 0, "Call-history count must not be negative")
        guard count > 0 else {
            return
        }

        // Each recorded argument is matched once; later checks only look at newer invocations.
        var progress = WaitProgress()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let generation = progress.update(with: snapshot(), matching: matching)
            if progress.matched >= count {
                return
            }
            if clock.now >= deadline {
                throw MockWaitError.timedOut(member: member, expectedCount: count, actualCount: progress.matched)
            }

            let result = try await waitForChange(
                after: generation,
                until: deadline,
                clock: clock
            )
            if result == .timedOut {
                progress.update(with: snapshot(), matching: matching)
                if progress.matched >= count {
                    return
                }
                throw MockWaitError.timedOut(member: member, expectedCount: count, actualCount: progress.matched)
            }
        }
    }

    private func matchingCount(in arguments: ArraySlice<Arguments>) -> Int {
        var count = 0
        for argument in arguments where matching(argument) {
            count += 1
        }
        return count
    }

    private func waitForChange(
        after generation: UInt64,
        until deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> WaitResult {
        try await withThrowingTaskGroup(of: WaitResult.self) { group in
            group.addTask {
                try await waitForChange(generation)
                return .changed
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                preconditionFailure("Wait task group unexpectedly completed without a result")
            }
            return result
        }
    }
}

/// Matching progress over append-only invocations, restarted when invocations are reset.
private struct WaitProgress {
    private(set) var matched = 0
    private var scanned = 0
    private var resets: UInt64?

    /// Matches arguments recorded since the last update and returns the snapshot's generation.
    @discardableResult mutating func update<Arguments>(
        with snapshot: CallHistorySnapshot<Arguments>,
        matching: (Arguments) -> Bool
    ) -> UInt64 {
        if snapshot.resets != resets {
            resets = snapshot.resets
            matched = 0
            scanned = 0
        }
        for argument in snapshot.arguments[scanned...] where matching(argument) {
            matched += 1
        }
        scanned = snapshot.arguments.count
        return snapshot.generation
    }
}
