@_exported public import Mocksmith
import Testing

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Count = .atLeast(1),
    sourceLocation: SourceLocation = #_sourceLocation
) -> M.Verify {
    mock.verification(count: count) {
        record($0, sourceLocation: sourceLocation)
    }
}

public func Verify<M: Mock>(
    _ mock: M,
    _ count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) -> M.Verify {
    Verify(mock, .exactly(count), sourceLocation: sourceLocation)
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Count = .atLeast(1),
    sourceLocation: SourceLocation = #_sourceLocation
) -> M.StaticVerify {
    M.verification(count: count) {
        record($0, sourceLocation: sourceLocation)
    }
}

public func Verify<M: StaticMock>(
    _ mock: M.Type,
    _ count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) -> M.StaticVerify {
    Verify(mock, .exactly(count), sourceLocation: sourceLocation)
}

public func VerifyInOrder(
    _ mode: InOrderMode = .strict,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (InOrder) -> Void
) {
    let order = InOrder(mode: mode)
    body(order)
    record(order.verification(), sourceLocation: sourceLocation)
}

public func VerifyNoMoreInteractions(
    _ mock: some _MocksmithExhaustiveMock,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    record(_mocksmithNoMoreInteractionsResult(mock._mocksmithUnverifiedInvocations), sourceLocation: sourceLocation)
}

public func VerifyNoMoreInteractions<M: _MocksmithExhaustiveStaticMock>(
    _ mock: M.Type,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    record(_mocksmithNoMoreInteractionsResult(M._mocksmithUnverifiedInvocations), sourceLocation: sourceLocation)
}

public extension CallHistory {
    /// Waits for matching calls and records a test failure if the wait fails.
    func expectCount(
        _ count: Int,
        timeout: Duration,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async {
        await expectCount(count, timeout: timeout, sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    /// Waits for matching calls and records a test failure at `sourceLocation` if the wait fails.
    func expectCount(
        _ count: Int,
        timeout: Duration,
        sourceLocation: SourceLocation
    ) async {
        do {
            try await waitForCount(count, timeout: timeout)
        } catch {
            Issue.record(Comment(rawValue: mocksmithAdapterMessage(for: error)), sourceLocation: sourceLocation)
        }
    }

    /// Returns the sole matching argument, recording a test failure otherwise.
    func requireOnlyArgument(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws -> Arguments {
        try requireOnlyArgument(sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    /// Returns the sole matching argument, recording a test failure at `sourceLocation` otherwise.
    func requireOnlyArgument(
        sourceLocation: SourceLocation
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
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws -> Arguments {
        try requireLastArgument(sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    /// Returns the last matching argument, recording a test failure at `sourceLocation` if none exists.
    func requireLastArgument(
        sourceLocation: SourceLocation
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
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async {
        await expectCalled(count: count, timeout: timeout, sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    /// Waits for pending invocations and records a test failure at `sourceLocation` if the wait fails.
    func expectCalled(
        count: Int = 1,
        timeout: Duration,
        sourceLocation: SourceLocation
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
