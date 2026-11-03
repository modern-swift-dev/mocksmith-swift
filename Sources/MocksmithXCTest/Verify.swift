@_exported public import Mocksmith
import XCTest

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Count = .atLeast(1),
    file: StaticString = #filePath,
    line: UInt = #line
) -> M.Verify {
    mock.verification(count: count) {
        report($0, file: file, line: line)
    }
}

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) -> M.Verify {
    Verify(mock, .exactly(count), file: file, line: line)
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Count = .atLeast(1),
    file: StaticString = #filePath,
    line: UInt = #line
) -> M.StaticVerify {
    M.verification(count: count) {
        report($0, file: file, line: line)
    }
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) -> M.StaticVerify {
    Verify(mock, .exactly(count), file: file, line: line)
}

public func VerifyInOrder(
    _ mode: InOrderMode = .strict,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (InOrder) -> Void
) {
    let order = InOrder(mode: mode)
    body(order)
    report(order.verification(), file: file, line: line)
}

public func VerifyNoMoreInteractions(
    _ mock: some _MocksmithExhaustiveMock,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    report(_mocksmithNoMoreInteractionsResult(mock._mocksmithUnverifiedInvocations), file: file, line: line)
}

public func VerifyNoMoreInteractions<M: _MocksmithExhaustiveStaticMock>(
    _ mock: M.Type,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    report(_mocksmithNoMoreInteractionsResult(M._mocksmithUnverifiedInvocations), file: file, line: line)
}

public extension CallHistory {
    /// Waits for matching calls and reports a test failure if the wait fails.
    func expectCount(
        _ count: Int,
        timeout: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await waitForCount(count, timeout: timeout)
        } catch {
            XCTFail(mocksmithAdapterMessage(for: error), file: file, line: line)
        }
    }

    /// Returns the sole matching argument, reporting a test failure otherwise.
    func requireOnlyArgument(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Arguments {
        do {
            return try onlyArgument
        } catch let error as CallHistoryError {
            XCTFail(mocksmithAdapterMessage(for: error), file: file, line: line)
            throw error
        }
    }

    /// Returns the last matching argument, reporting a test failure if none exists.
    func requireLastArgument(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Arguments {
        guard let argument = lastArgument else {
            let error = CallHistoryError.expectedAtLeastOne(member: _mocksmithMemberName)
            XCTFail(mocksmithAdapterMessage(for: error), file: file, line: line)
            throw error
        }
        return argument
    }
}

public extension PendingCall {
    /// Waits for pending invocations and reports a test failure if the wait fails.
    func expectCalled(
        count: Int = 1,
        timeout: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await waitUntilCalled(count: count, timeout: timeout)
        } catch {
            XCTFail(mocksmithAdapterMessage(for: error), file: file, line: line)
        }
    }
}

private func report(_ result: VerificationResult, file: StaticString, line: UInt) {
    guard !result.success else {
        return
    }
    XCTFail(result.message, file: file, line: line)
}

private func mocksmithAdapterMessage(for error: Error) -> String {
    switch error {
        case let .timedOut(member, expectedCount, actualCount) as MockWaitError:
            "Timed out waiting for \(expectedCount) call(s) to \(member); received \(actualCount)."
        case let .expectedExactlyOne(member, actualCount) as CallHistoryError:
            "Expected exactly one matching call to \(member); received \(actualCount)."
        case let .expectedAtLeastOne(member) as CallHistoryError:
            "Expected at least one matching call to \(member)."
        case is CancellationError:
            "Waiting for mock calls was cancelled."
        default:
            "Waiting for mock calls failed: \(error)."
    }
}
