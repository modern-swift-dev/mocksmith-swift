import Mocksmith
import MocksmithTesting
import MocksmithXCTest
import Testing
import XCTest

final class AdapterTests: XCTestCase {
    func testInstanceAdaptersAcceptSuccessfulVerification() {
        let mock = InstanceMock()

        MocksmithTesting.Verify(mock, .atLeast(1)).check()
        MocksmithTesting.Verify(mock, 1).check()
        MocksmithXCTest.Verify(mock, .atLeast(1)).check()
        MocksmithXCTest.Verify(mock, 1).check()
        MocksmithTesting.VerifyNoMoreInteractions(mock)
        MocksmithXCTest.VerifyNoMoreInteractions(mock)
    }

    func testStaticAdaptersAcceptSuccessfulVerification() {
        MocksmithTesting.Verify(StaticTestMock.self, .atLeast(1)).check()
        MocksmithTesting.Verify(StaticTestMock.self, 1).check()
        MocksmithXCTest.Verify(StaticTestMock.self, .atLeast(1)).check()
        MocksmithXCTest.Verify(StaticTestMock.self, 1).check()
        MocksmithTesting.VerifyNoMoreInteractions(StaticTestMock.self)
        MocksmithXCTest.VerifyNoMoreInteractions(StaticTestMock.self)
    }

    func testXCTestInOrderAdapterAcceptsSuccessfulVerification() {
        MocksmithXCTest.VerifyInOrder { order in
            order._append(
                source: InstanceMock(),
                invocations: { [_MocksmithInvocation(sequence: 1, member: "check")] },
                member: "check",
                matches: { $0 == 1 },
                markVerified: { _ in }
            )
        }
    }

    #if canImport(Darwin)
        func testXCTestInOrderAdapterReportsBlockLocation() {
            let expectedLine: UInt = 4243
            XCTExpectFailure(
                "The in-order adapter failure is intentional",
                strict: true,
                failingBlock: {
                    MocksmithXCTest.VerifyInOrder(file: #filePath, line: expectedLine) { _ in }
                },
                issueMatcher: { issue in
                    issue.compactDescription.contains("In-order verification needs at least one expected invocation")
                        && issue.sourceCodeContext.location?.lineNumber == Int(expectedLine)
                }
            )
        }

        func testXCTestAdapterReportsMessageAndSourceLocation() {
            let expectedLine: UInt = 4242
            XCTExpectFailure(
                "The adapter failure is intentional",
                strict: true,
                failingBlock: {
                    MocksmithXCTest.Verify(FailingMock(), 1, file: #filePath, line: expectedLine).check()
                },
                issueMatcher: { issue in
                    issue.compactDescription.contains("adapter failure")
                        && issue.sourceCodeContext.location?.lineNumber == Int(expectedLine)
                }
            )
        }

        func testXCTestNoMoreInteractionsReportsMessageAndSourceLocation() {
            let expectedLine: UInt = 4244
            XCTExpectFailure(
                "The exhaustive adapter failure is intentional",
                strict: true,
                failingBlock: {
                    MocksmithXCTest.VerifyNoMoreInteractions(FailingMock(), file: #filePath, line: expectedLine)
                },
                issueMatcher: { issue in
                    issue.compactDescription.contains("Unverified interactions: load(*:) ×2, save(*:) ×1")
                        && issue.sourceCodeContext.location?.lineNumber == Int(expectedLine)
                }
            )
        }

        func testXCTestStaticNoMoreInteractionsReportsMessageAndSourceLocation() {
            let expectedLine: UInt = 4245
            XCTExpectFailure(
                "The static exhaustive adapter failure is intentional",
                strict: true,
                failingBlock: {
                    MocksmithXCTest.VerifyNoMoreInteractions(FailingStaticMock.self, file: #filePath, line: expectedLine)
                },
                issueMatcher: { issue in
                    issue.compactDescription.contains("Unverified interactions: load(*:) ×2, save(*:) ×1")
                        && issue.sourceCodeContext.location?.lineNumber == Int(expectedLine)
                }
            )
        }
    #endif
}

@Test private func swiftTestingAdapterReportsMessageAndSourceLocation() {
    let location = SourceLocation(
        fileID: #fileID,
        filePath: #filePath,
        line: 4242,
        column: 7
    )

    withKnownIssue {
        MocksmithTesting.Verify(FailingMock(), 1, sourceLocation: location).check()
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "adapter failure"))
    }
}

@Test private func swiftTestingInOrderAdapterReportsBlockLocation() {
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 4243, column: 8)

    withKnownIssue {
        MocksmithTesting.VerifyInOrder(sourceLocation: location) { _ in }
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "In-order verification needs at least one expected invocation"))
    }
}

@Test private func swiftTestingNoMoreInteractionsReportsMessageAndSourceLocation() {
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 4244, column: 9)

    withKnownIssue {
        MocksmithTesting.VerifyNoMoreInteractions(FailingMock(), sourceLocation: location)
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "Unverified interactions: load(*:) ×2, save(*:) ×1"))
    }
}

@Test private func swiftTestingStaticNoMoreInteractionsReportsMessageAndSourceLocation() {
    let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 4245, column: 10)

    withKnownIssue {
        MocksmithTesting.VerifyNoMoreInteractions(FailingStaticMock.self, sourceLocation: location)
    } matching: { issue in
        issue.sourceLocation == location
            && issue.comments.contains(Comment(rawValue: "Unverified interactions: load(*:) ×2, save(*:) ×1"))
    }
}

private final class InstanceMock: Mock, _MocksmithExhaustiveMock {
    typealias Given = Void
    typealias Verify = AdapterVerify
    typealias Perform = Void

    func given() {}
    func perform() {}

    func verification(
        count: Count,
        report: @escaping (VerificationResult) -> Void
    ) -> AdapterVerify {
        AdapterVerify(result: VerificationResult(success: true, message: ""), report: report)
    }

    func resetMock(_ scopes: MockScope...) {}

    var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        []
    }
}

private final class StaticTestMock: StaticMock, _MocksmithExhaustiveStaticMock {
    typealias StaticGiven = Void
    typealias StaticVerify = AdapterVerify
    typealias StaticPerform = Void

    static func given() {}
    static func perform() {}

    static func verification(
        count: Count,
        report: @escaping (VerificationResult) -> Void
    ) -> AdapterVerify {
        AdapterVerify(result: VerificationResult(success: true, message: ""), report: report)
    }

    static func resetMock(_ scopes: MockScope...) {}

    static var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        []
    }
}

private final class FailingMock: Mock, _MocksmithExhaustiveMock {
    typealias Given = Void
    typealias Verify = AdapterVerify
    typealias Perform = Void

    func given() {}
    func perform() {}

    func verification(
        count: Count,
        report: @escaping (VerificationResult) -> Void
    ) -> AdapterVerify {
        AdapterVerify(result: VerificationResult(success: false, message: "adapter failure"), report: report)
    }

    func resetMock(_ scopes: MockScope...) {}

    var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        [
            .init(sequence: 1, member: "load(_:)"),
            .init(sequence: 2, member: "save(_:)"),
            .init(sequence: 3, member: "load(_:)")
        ]
    }
}

private final class FailingStaticMock: StaticMock, _MocksmithExhaustiveStaticMock {
    typealias StaticGiven = Void
    typealias StaticVerify = AdapterVerify
    typealias StaticPerform = Void

    static func given() {}
    static func perform() {}

    static func verification(
        count: Count,
        report: @escaping (VerificationResult) -> Void
    ) -> AdapterVerify {
        AdapterVerify(result: VerificationResult(success: true, message: ""), report: report)
    }

    static func resetMock(_ scopes: MockScope...) {}

    static var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
        [
            .init(sequence: 1, member: "load(_:)"),
            .init(sequence: 2, member: "save(_:)"),
            .init(sequence: 3, member: "load(_:)")
        ]
    }
}

private struct AdapterVerify {
    let result: VerificationResult
    let report: (VerificationResult) -> Void

    func check() {
        report(result)
    }
}
