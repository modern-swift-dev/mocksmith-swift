import Foundation
import Mocksmith
import Testing

private enum PendingFailure: Error, Equatable {
    case cancelled
    case configured
}

private typealias PendingBuilder = _MocksmithAsyncThrowingReturnStub<Int, Void, String, PendingFailure, (Int) async throws -> String>

private func pendingBuilder(_ member: MockMember<Int, Void, String>) -> PendingBuilder {
    PendingBuilder(
        member: "fetch(_:)",
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering(answer) }
    )
}

@Test func pendingCallsResumeInFIFOOrderAndRetainArguments() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let pending = pendingBuilder(member).willSuspend()
    let first = Task { try await member.invokeAsync(1) }
    try await pending.waitUntilCalled(timeout: .seconds(1))
    let second = Task { try await member.invokeAsync(2) }

    try await pending.waitUntilCalled(count: 2, timeout: .seconds(1))
    #expect(pending.callCount == 2)
    #expect(pending.arguments == [1, 2])

    pending.resume(returning: "first")
    pending.resume(returning: "second")
    #expect(try await first.value == "first")
    #expect(try await second.value == "second")
}

@Test func pendingControlCanBeStoredWithoutTheFluentSequenceType() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let control: PendingCall<Int, String, PendingFailure> = pendingBuilder(member).willSuspend().control
    let task = Task { try await member.invokeAsync(42) }

    try await control.waitUntilCalled(timeout: .seconds(1))
    #expect(control.callCount == 1)
    #expect(control.arguments == [42])
    control.resume(with: .success("stored"))
    #expect(try await task.value == "stored")
}

@Test func pendingControlResumesFailuresFromResults() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let control = pendingBuilder(member).willSuspend().control
    let task = Task { try await member.invokeAsync(1) }

    try await control.waitUntilCalled(timeout: .seconds(1))
    control.resume(with: .failure(.configured))
    await #expect(throws: PendingFailure.configured) { try await task.value }
}

@Test func waitingUntilCalledAlwaysObservesAResumableInvocation() async throws {
    for iteration in 0 ..< 100 {
        let member = MockMember<Int, Void, Int>(name: "iteration")
        let builder = _MocksmithAsyncReturnStub<Int, Void, Int, (Int) async -> Int>(
            member: "iteration",
            apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
            answer: { answer in .answering(answer) }
        )
        let pending = builder.willSuspend()
        let task = Task { try await member.invokeAsync(iteration) }
        try await pending.waitUntilCalled(timeout: .seconds(1))
        pending.resume(returning: iteration)
        #expect(try await task.value == iteration)
    }
}

@Test func pendingOutcomeRepeatsAndSelectedCallsSurviveReset() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let pending = pendingBuilder(member).willSuspend()
    let first = Task { try await member.invokeAsync(1) }
    try await pending.waitUntilCalled(timeout: .seconds(1))
    member.reset([.stubs])
    pending.resume(returning: "selected")
    #expect(try await first.value == "selected")
    await #expect(throws: MockError.self) { try await member.invokeAsync(2) }

    let repeated = pendingBuilder(member).willSuspend()
    let second = Task { try await member.invokeAsync(2) }
    try await repeated.waitUntilCalled(timeout: .seconds(1))
    let third = Task { try await member.invokeAsync(3) }
    try await repeated.waitUntilCalled(count: 2, timeout: .seconds(1))
    repeated.resume(returning: "two")
    repeated.resume(returning: "three")
    #expect(try await second.value == "two")
    #expect(try await third.value == "three")
}

@Test func pendingSequenceMixesAnswersFailuresAndDistinctSuspensions() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let first = pendingBuilder(member).willSuspend()
    let second = first
        .thenReturn("fixed")
        .thenThrow(.configured)
        .thenAnswer { "answer-\($0)" }
        .thenSuspend()

    let one = Task { try await member.invokeAsync(1) }
    try await first.waitUntilCalled(timeout: .seconds(1))
    first.resume(returning: "pending")
    #expect(try await one.value == "pending")
    #expect(try await member.invokeAsync(2) == "fixed")
    await #expect(throws: PendingFailure.configured) { try await member.invokeAsync(3) }
    #expect(try await member.invokeAsync(4) == "answer-4")

    let five = Task { try await member.invokeAsync(5) }
    try await second.waitUntilCalled(timeout: .seconds(1))
    #expect(first.callCount == 1)
    #expect(second.arguments == [5])
    second.resume(returning: "second pending")
    #expect(try await five.value == "second pending")
}

@Test func cancellationCanBeIgnoredOrMappedToFailure() async throws {
    let ignoredMember = MockMember<Int, Void, String>(name: "ignored")
    let ignored = pendingBuilder(ignoredMember).willSuspend()
    let ignoredTask = Task { try await ignoredMember.invokeAsync(1) }
    try await ignored.waitUntilCalled(timeout: .seconds(1))
    ignoredTask.cancel()
    ignored.resume(returning: "still pending")
    #expect(try await ignoredTask.value == "still pending")

    let failedMember = MockMember<Int, Void, String>(name: "failed")
    let failed = pendingBuilder(failedMember).willSuspend(cancellation: .fail(with: .cancelled))
    let failedTask = Task { try await failedMember.invokeAsync(2) }
    try await failed.waitUntilCalled(timeout: .seconds(1))
    failedTask.cancel()
    await #expect(throws: PendingFailure.cancelled) { try await failedTask.value }
    #expect(failed.callCount == 1)
    #expect(failed.arguments == [2])
}

@Test func pendingVoidCallsResumeAndChainSuccess() async throws {
    let member = MockMember<Void, Void, Void>(name: "refresh")
    let builder = _MocksmithAsyncThrowingReturnStub<Void, Void, Void, PendingFailure, () async throws -> Void>(
        member: "refresh",
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { _ in try await answer() } }
    )
    let pending = builder.willSuspend().thenSucceed()
    let first = Task { try await member.invokeAsync(()) }
    try await pending.waitUntilCalled(timeout: .seconds(1))
    pending.resume()
    try await first.value
    try await member.invokeAsync(())
}

@Test func asyncThrowingBuildersResolveResultSequences() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let builder = pendingBuilder(member)
    builder.willResolve(.success("first"), .failure(.configured))
        .thenResolve(.success("last"))

    #expect(try await member.invokeAsync(1) == "first")
    await #expect(throws: PendingFailure.configured) { try await member.invokeAsync(2) }
    #expect(try await member.invokeAsync(3) == "last")
    #expect(try await member.invokeAsync(4) == "last")
}

@Test func throwingVoidBuildersResolveResultSequences() throws {
    let member = MockMember<Void, Void, Void>(name: "refresh")
    let builder = _MocksmithThrowingVoidStub<Void, Void, PendingFailure, () throws -> Void>(
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { _, _ in try answer() } }
    )
    builder.willResolve(.success(()), .failure(.configured))
        .thenResolve(.success(()))

    try member.invoke(())
    #expect(throws: PendingFailure.configured) { try member.invoke(()) }
    try member.invoke(())
}

@Test func throwingReturnBuildersResolveResultSequences() throws {
    let member = MockMember<Int, Void, Int>(name: "load(_:)")
    let builder = _MocksmithThrowingReturnStub<Int, Void, Int, PendingFailure, (Int) throws -> Int>(
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { arguments, _ in try answer(arguments) } }
    )
    builder.willResolve(.success(1)).thenResolve(.failure(.configured), .success(3))

    #expect(try member.invoke(0) == 1)
    #expect(throws: PendingFailure.configured) { try member.invoke(0) }
    #expect(try member.invoke(0) == 3)
}

@Test func pendingSequencesAppendResolvedResults() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let pending = pendingBuilder(member).willSuspend().thenResolve(.failure(.configured), .success("resolved"))
    let task = Task { try await member.invokeAsync(1) }

    try await pending.waitUntilCalled(timeout: .seconds(1))
    pending.resume(returning: "suspended")
    #expect(try await task.value == "suspended")
    await #expect(throws: PendingFailure.configured) { try await member.invokeAsync(2) }
    #expect(try await member.invokeAsync(3) == "resolved")
}

@Test func invocationCancelledBeforeSuspendingFailsButIsRecorded() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let first = pendingBuilder(member).willSuspend(cancellation: .fail(with: .cancelled))
    let second = first.thenSuspend()
    let task = Task {
        while !Task.isCancelled {
            await Task.yield()
        }
        return try await member.invokeAsync(1)
    }
    task.cancel()

    await #expect(throws: PendingFailure.cancelled) { try await task.value }
    #expect(first.arguments == [1])

    let next = Task { try await member.invokeAsync(2) }
    try await second.waitUntilCalled(timeout: .seconds(1))
    second.resume(returning: "second")
    #expect(try await next.value == "second")
}

@Test func cancellingWaitUntilCalledRemovesTheWaiter() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let pending = pendingBuilder(member).willSuspend()
    let waiting = Task { try await pending.waitUntilCalled(timeout: .seconds(10)) }

    await Task.yield()
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }

    let task = Task { try await member.invokeAsync(1) }
    try await pending.waitUntilCalled(timeout: .seconds(1))
    pending.resume(returning: "resumed")
    #expect(try await task.value == "resumed")
}

@Test func pendingHandlesResumeFromAnotherTask() async throws {
    let member = MockMember<Int, Void, String>(name: "fetch(_:)")
    let pending = pendingBuilder(member).willSuspend()
    let task = Task { try await member.invokeAsync(1) }

    try await Task.detached {
        try await pending.waitUntilCalled(timeout: .seconds(1))
        pending.resume(with: .success("detached"))
    }.value
    #expect(try await task.value == "detached")
}
