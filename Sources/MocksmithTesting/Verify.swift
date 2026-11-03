@_exported public import Mocksmith
import Testing

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Count = .atLeast(1),
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) -> M.Verify {
    mock.verification(count: count) {
        record($0, sourceLocation: sourceLocation)
    }
}

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Int,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) -> M.Verify {
    Verify(mock, .exactly(count), sourceLocation: sourceLocation)
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Count = .atLeast(1),
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) -> M.StaticVerify {
    M.verification(count: count) {
        record($0, sourceLocation: sourceLocation)
    }
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Int,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) -> M.StaticVerify {
    Verify(mock, .exactly(count), sourceLocation: sourceLocation)
}

public func VerifyInOrder(
    _ mode: InOrderMode = .strict,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column),
    _ body: (InOrder) -> Void
) {
    let order = InOrder(mode: mode)
    body(order)
    record(order.verification(), sourceLocation: sourceLocation)
}

public func VerifyNoMoreInteractions(
    _ mock: some _MocksmithExhaustiveMock,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) {
    record(_mocksmithNoMoreInteractionsResult(mock._mocksmithUnverifiedInvocations), sourceLocation: sourceLocation)
}

public func VerifyNoMoreInteractions<M: _MocksmithExhaustiveStaticMock>(
    _ mock: M.Type,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
) {
    record(_mocksmithNoMoreInteractionsResult(M._mocksmithUnverifiedInvocations), sourceLocation: sourceLocation)
}

public extension CallHistory {
    /// Waits for matching calls and records a test failure if the wait fails.
    func expectCount(
        _ count: Int,
        timeout: Duration,
        sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
    ) async {
        do {
            try await waitForCount(count, timeout: timeout)
        } catch {
            Issue.record(Comment(rawValue: mocksmithAdapterMessage(for: error)), sourceLocation: sourceLocation)
        }
    }

    /// Returns the sole matching argument, recording a test failure otherwise.
    func requireOnlyArgument(
        sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
    ) throws -> Arguments {
        do {
            return try onlyArgument
        } catch let error as CallHistoryError {
            Issue.record(Comment(rawValue: mocksmithAdapterMessage(for: error)), sourceLocation: sourceLocation)
            throw error
        }
    }

    /// Returns the last matching argument, recording a test failure if none exists.
    func requireLastArgument(
        sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
    ) throws -> Arguments {
        guard let argument = lastArgument else {
            let error = CallHistoryError.expectedAtLeastOne(member: _mocksmithMemberName)
            Issue.record(Comment(rawValue: mocksmithAdapterMessage(for: error)), sourceLocation: sourceLocation)
            throw error
        }
        return argument
    }
}

public extension PendingCall {
    /// Waits for pending invocations and records a test failure if the wait fails.
    func expectCalled(
        count: Int = 1,
        timeout: Duration,
        sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
    ) async {
        do {
            try await waitUntilCalled(count: count, timeout: timeout)
        } catch {
            Issue.record(Comment(rawValue: mocksmithAdapterMessage(for: error)), sourceLocation: sourceLocation)
        }
    }
}

private func record(_ result: VerificationResult, sourceLocation: SourceLocation) {
    guard !result.success else {
        return
    }
    Issue.record(Comment(rawValue: result.message), sourceLocation: sourceLocation)
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
