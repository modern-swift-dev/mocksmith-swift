import Mocksmith
import Testing

@Test func callHistoryRetainsTypedArgumentsInInvocationOrder() throws {
    let member = MockMember<(key: String, value: Int), Void, Void>(name: "save")
    member.record((key: "first", value: 1))
    member.record((key: "second", value: 2))

    let history = member.callHistory { $0.value.isMultiple(of: 2) }
    #expect(history.count == 1)
    #expect(try history.onlyArgument.key == "second")
    #expect(history.arguments.map(\.value) == [2])
}

@Test func callHistoryOnlyArgumentReportsActualCount() {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { _ in true }

    #expect(throws: CallHistoryError.expectedExactlyOne(member: "save", actualCount: 0)) {
        try history.onlyArgument
    }

    member.record(1)
    member.record(2)
    #expect(throws: CallHistoryError.expectedExactlyOne(member: "save", actualCount: 2)) {
        try history.onlyArgument
    }
}

@Test func callHistoryExposesOptionalPositionalArguments() {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { _ in true }

    #expect(history.firstArgument == nil)
    #expect(history.lastArgument == nil)
    #expect(history.argument(at: -1) == nil)
    #expect(history.argument(at: 0) == nil)

    member.record(1)
    member.record(2)
    #expect(history.firstArgument == 1)
    #expect(history.lastArgument == 2)
    #expect(history.argument(at: 0) == 1)
    #expect(history.argument(at: 1) == 2)
    #expect(history.argument(at: 2) == nil)
}

@Test func callHistoryWaitsForRecordedCalls() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { $0 > 0 }
    let waiting = Task {
        try await history.waitForCount(2, timeout: .seconds(1))
    }

    await Task.yield()
    member.record(1)
    member.record(2)
    try await waiting.value
    #expect(history.arguments == [1, 2])
}

@Test func callHistoryReturnsImmediatelyForExistingAndZeroCounts() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    member.record(1)
    let history = member.callHistory { _ in true }

    try await history.waitForCount(1, timeout: .seconds(1))
    try await history.waitForCount(0, timeout: .seconds(1))
}

@Test func callHistoryWakesMultipleWaiters() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { _ in true }
    let first = Task { try await history.waitForCount(1, timeout: .seconds(1)) }
    let second = Task { try await history.waitForCount(1, timeout: .seconds(1)) }

    await Task.yield()
    member.record(1)
    try await first.value
    try await second.value
}

@Test func callHistoryResetWakesWaitersAndResnapshots() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    member.record(1)
    let history = member.callHistory { _ in true }
    let waiting = Task { try await history.waitForCount(2, timeout: .seconds(1)) }

    await Task.yield()
    member.reset([.invocations])
    member.record(1)
    member.record(2)
    try await waiting.value
    #expect(history.count == 2)
}

@Test func callHistoryMatcherCanReenterMember() {
    let member = MockMember<Int, Void, Void>(name: "save")
    member.record(1)
    let history = member.callHistory { value in
        member.record(value + 1)
        return value == 1
    }

    #expect(history.count == 1)
    #expect(member.invocationCount(matching: { _ in true }) == 2)
}

@Test func callHistoryHandlesCancellationBeforeWaiting() async {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { _ in true }
    let waiting = Task {
        try await history.waitForCount(1, timeout: .seconds(1))
    }
    waiting.cancel()

    await #expect(throws: CancellationError.self) {
        try await waiting.value
    }
}

@Test func callHistoryDoesNotMissImmediateRecordsWhileRegistering() async throws {
    for _ in 0 ..< 100 {
        let member = MockMember<Int, Void, Void>(name: "save")
        let history = member.callHistory { _ in true }
        let waiting = Task {
            try await history.waitForCount(1, timeout: .seconds(1))
        }
        member.record(1)
        try await waiting.value
    }
}

@Test func callHistoryWaitTimeoutIncludesMatchingCount() async {
    let member = MockMember<Int, Void, Void>(name: "save")
    member.record(1)
    let history = member.callHistory { $0 > 0 }

    await #expect(throws: MockWaitError.timedOut(member: "save", expectedCount: 2, actualCount: 1)) {
        try await history.waitForCount(2, timeout: .milliseconds(10))
    }
}

@Test func callHistoryCancellationRemovesWaiter() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    let history = member.callHistory { _ in true }
    let waiting = Task {
        try await history.waitForCount(1, timeout: .seconds(1))
    }

    await Task.yield()
    waiting.cancel()
    await #expect(throws: CancellationError.self) {
        try await waiting.value
    }

    member.record(1)
    #expect(history.count == 1)
}

@Test func callHistoryDoesNotMarkInvocationsVerified() {
    let member = MockMember<Int, Void, Void>(name: "save")
    member.record(1)

    #expect(member.callHistory(matching: { $0 == 1 }).count == 1)
    #expect(member._mocksmithUnverifiedInvocations.count == 1)
}

/// Yields until `condition` holds, failing instead of hanging if it never does.
private func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
    #expect(condition())
}

@Test func callHistoryWaitMatchesEachInvocationOnce() async throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    let evaluations = EvaluationCounter()
    let history = member.callHistory { _ in evaluations.increment(); return true }
    let recorded = 50
    let waiting = Task { try await history.waitForCount(recorded, timeout: .seconds(5)) }

    // Each record wakes the waiter; rescanning everything on wake-up would be quadratic.
    for value in 1 ... recorded {
        member.record(value)
        await eventually { evaluations.value >= value }
    }
    try await waiting.value
    #expect(evaluations.value == recorded)
}

@Test func callHistoryWaitRestartsMatchingAfterReset() async {
    let member = MockMember<Int, Void, Void>(name: "save")
    let evaluations = EvaluationCounter()
    let history = member.callHistory { _ in evaluations.increment(); return true }
    member.record(1)
    member.record(2)
    let waiting = Task { try await history.waitForCount(3, timeout: .milliseconds(200)) }
    await eventually { evaluations.value >= 2 }

    member.reset([.invocations])
    member.record(3)
    await #expect(throws: MockWaitError.timedOut(member: "save", expectedCount: 3, actualCount: 1)) {
        try await waiting.value
    }
    #expect(evaluations.value == 3)
}

@Test func callHistoryAccessorsMatchLazily() throws {
    let member = MockMember<Int, Void, Void>(name: "save")
    let evaluations = EvaluationCounter()
    let history = member.callHistory { evaluations.increment(); return $0.isMultiple(of: 2) }
    for value in 1 ... 10 {
        member.record(value)
    }

    #expect(history.firstArgument == 2)
    #expect(evaluations.value == 2)
    #expect(history.lastArgument == 10)
    #expect(evaluations.value == 3)
    #expect(history.argument(at: 1) == 4)
    #expect(history.count == 5)
    #expect(history.arguments == [2, 4, 6, 8, 10])
    #expect(throws: CallHistoryError.expectedExactlyOne(member: "save", actualCount: 5)) {
        try history.onlyArgument
    }
}
