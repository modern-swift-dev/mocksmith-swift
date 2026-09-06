import Mocksmith
import MocksmithXCTest
import XCTest

final class XCTestCallHistoryAdapterTests: XCTestCase {
    func testCallAssertionsSucceed() async throws {
        let member = MockMember<Int, Void, Void>(name: "save(_:)")
        let history = member.callHistory { _ in true }
        member.record(1)

        await history.expectCount(1, timeout: .seconds(1))
        XCTAssertEqual(try history.requireOnlyArgument(), 1)
        XCTAssertEqual(try history.requireLastArgument(), 1)
    }

    #if canImport(Darwin)
        func testRequirementReportsSourceLocation() throws {
            let member = MockMember<Int, Void, Void>(name: "save(_:)")
            let history = member.callHistory { _ in true }
            let expectedLine: UInt = 5254

            try XCTExpectFailure(
                "The empty-history failure is intentional",
                strict: true,
                failingBlock: {
                    XCTAssertThrowsError(try history.requireLastArgument(file: #filePath, line: expectedLine))
                },
                issueMatcher: { issue in
                    issue.compactDescription.contains("Expected at least one matching call to save(_:).")
                        && issue.sourceCodeContext.location?.lineNumber == Int(expectedLine)
                }
            )
        }
    #endif
}
