import Mocksmith
import MocksmithTesting
import MocksmithXCTest
import Testing
import XCTest

@Mockable(.macro) private protocol IsolatedStaticService {
    static func value() -> Int
}

private func stubCallAndVerify(_ value: Int) async {
    Given(IsolatedStaticServiceMock.self).value().willReturn(value)
    // Give tests running in parallel a chance to stub the same static member.
    await Task.yield()
    #expect(IsolatedStaticServiceMock.value() == value)
    MocksmithTesting.Verify(IsolatedStaticServiceMock.self, 1).value()
}

@Suite(.isolatedStaticMocks) struct IsolatedStaticMockSuiteTests {
    @Test func stubsOne() async {
        await stubCallAndVerify(1)
    }

    @Test func stubsTwo() async {
        await stubCallAndVerify(2)
    }
}

@Test(.isolatedStaticMocks, arguments: 1 ... 20) private func parallelCasesStubStaticMockIndependently(value: Int) async {
    await stubCallAndVerify(value)
}

final class StaticMockIsolationXCTests: XCTestCase {
    func testWithIsolatedStaticMocksScopesStaticState() async {
        await withIsolatedStaticMocks {
            Given(IsolatedStaticServiceMock.self).value().willReturn(7)
            XCTAssertEqual(IsolatedStaticServiceMock.value(), 7)
            MocksmithXCTest.Verify(IsolatedStaticServiceMock.self, 1).value()
        }
    }
}
