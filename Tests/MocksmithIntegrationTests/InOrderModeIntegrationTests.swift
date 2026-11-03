import Mocksmith
import MocksmithTesting
import MocksmithXCTest
import Testing
import XCTest

@Mockable(.macro) private protocol OrderModeService {
    func record(_ value: Int)
}

private func makeInterleavedService() -> OrderModeServiceMock {
    let service = OrderModeServiceMock()
    Given(service).record(.any)
    service.record(1)
    service.record(9)
    service.record(2)
    return service
}

@Test private func swiftTestingRelaxedInOrderSkipsUnrelatedInvocations() {
    let service = makeInterleavedService()

    MocksmithTesting.VerifyInOrder(.relaxed) { order in
        order.expect(service).record(.value(1))
        order.expect(service).record(.value(2))
    }
    MocksmithTesting.Verify(service, 1).record(.value(9))
    MocksmithTesting.VerifyNoMoreInteractions(service)
}

@Test private func swiftTestingInOrderDefaultsToStrict() {
    let service = makeInterleavedService()

    withKnownIssue {
        MocksmithTesting.VerifyInOrder { order in
            order.expect(service).record(.value(1))
            order.expect(service).record(.value(2))
        }
    } matching: { issue in
        issue.comments.contains(Comment(rawValue: "Expected record_: after record_:, got record_: with non-matching arguments"))
    }
}

final class InOrderModeXCTests: XCTestCase {
    func testXCTestRelaxedInOrderSkipsUnrelatedInvocations() {
        let service = makeInterleavedService()

        MocksmithXCTest.VerifyInOrder(.relaxed) { order in
            order.expect(service).record(.value(1))
            order.expect(service).record(.value(2))
        }
    }
}
