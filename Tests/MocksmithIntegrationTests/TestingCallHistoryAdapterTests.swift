import Mocksmith
import MocksmithTesting
import Testing

@MainActor
@Mockable(.macro) private protocol AdapterPendingService {
    func load() async -> Int
}

@Test private func swiftTestingCallAssertionsSucceed() async throws {
    let member = MockMember<Int, Void, Void>(name: "save(_:)")
    let history = member.callHistory { _ in true }
    member.record(1)

    await history.expectCount(1, timeout: .seconds(1))
    #expect(try history.requireOnlyArgument() == 1)
    #expect(try history.requireLastArgument() == 1)
}

@Test @MainActor private func swiftTestingPendingAssertionSucceeds() async {
    let mock = AdapterPendingServiceMock()
    let pending = Given(mock).load().willSuspend().control
    let invocation = Task { await mock.load() }

    await pending.expectCalled(timeout: .seconds(1))
    pending.resume(returning: 42)
    #expect(await invocation.value == 42)
}

@Test private func swiftTestingWaitAssertionReportsTimeoutAtCaller() async {
    let member = MockMember<Int, Void, Void>(name: "save(_:)")
    let history = member.callHistory { _ in true }
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 5252, column: 4)

    await withKnownIssue {
        await history.expectCount(1, timeout: .milliseconds(1), sourceLocation: location)
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "Timed out waiting for 1 call(s) to save(_:); received 0."))
    }
}

@Test private func swiftTestingWaitAssertionReportsCancellationAtCaller() async {
    let member = MockMember<Int, Void, Void>(name: "save(_:)")
    let history = member.callHistory { _ in true }
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 5255, column: 6)

    await withKnownIssue {
        let waiting = Task {
            await history.expectCount(1, timeout: .seconds(1), sourceLocation: location)
        }
        waiting.cancel()
        await waiting.value
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "Waiting for mock calls was cancelled."))
    }
}

@Test private func swiftTestingRequirementReportsEmptyHistoryAtCaller() {
    let member = MockMember<Int, Void, Void>(name: "save(_:)")
    let history = member.callHistory { _ in true }
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 5253, column: 5)

    withKnownIssue {
        #expect(throws: CallHistoryError.expectedAtLeastOne(member: "save(_:)")) {
            try history.requireLastArgument(sourceLocation: location)
        }
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "Expected at least one matching call to save(_:)."))
    }
}
