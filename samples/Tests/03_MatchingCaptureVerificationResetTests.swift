import Mocksmith
import MocksmithTesting
import Testing

private struct ExternalID {
    let rawValue: String
}

private final class ReferenceItem {}

@Mockable(.macro) private protocol MatchingService {
    func identify(_ id: ExternalID) throws -> String
    func owns(_ item: ReferenceItem) -> Bool
    func record(_ value: Int)
}

@Test private func everyParameterMatcherHasAFocusedUse() throws {
    let service = MatchingServiceMock()
    let expectedReference = ReferenceItem()

    // `.value(_:by:)` supplies equality for values that are not Equatable.
    Given(service).identify(.value(ExternalID(rawValue: "A"), by: { $0.rawValue == $1.rawValue })).willReturn("custom equality")

    // `.matching` handles predicate-based rules. `.any` remains the fallback.
    Given(service).identify(.matching { $0.rawValue.hasPrefix("B") }).willReturn("predicate")
    Given(service).identify(.any).willReturn("fallback")

    // `.sameInstance` compares object identity with `===`, not value equality.
    Given(service).owns(.sameInstance(expectedReference)).willReturn(true)
    Given(service).owns(.any).willReturn(false)

    #expect(try service.identify(ExternalID(rawValue: "A")) == "custom equality")
    #expect(try service.identify(ExternalID(rawValue: "B-12")) == "predicate")
    #expect(try service.identify(ExternalID(rawValue: "C")) == "fallback")
    #expect(service.owns(expectedReference))
    #expect(!service.owns(ReferenceItem()))
}

@Test private func captorsAndEveryVerificationCountForm() {
    let service = MatchingServiceMock()
    let values = ArgumentCaptor<Int>()
    Given(service).record(.any)

    service.record(10)
    service.record(20)

    // A capturing matcher appends matching recorded arguments while Verify
    // scans invocations. Captors expose the full list and its final value.
    Verify(service, 2).record(.capturing(values))
    #expect(values.values == [10, 20])
    #expect(values.lastValue == 20)

    Verify(service, .exactly(2)).record(.any)
    Verify(service, .atLeast(1)).record(.any)
    Verify(service, .atMost(2)).record(.any)
    Verify(service, .between(1, 3)).record(.any)
    Verify(service, .between(1 ... 2)).record(.any)
    Verify(service, .never).record(.value(99))
    VerifyNoMoreInteractions(service)

    values.reset()
    #expect(values.values.isEmpty)
}

@Test private func strictOrderCanSpanMocks() {
    let first = MatchingServiceMock()
    let second = MatchingServiceMock()
    Given(first).record(.any)
    Given(second).record(.any)

    first.record(1)
    second.record(2)
    first.record(3)

    VerifyInOrder { order in
        order.expect(first).record(.value(1))
        order.expect(second).record(.value(2))
        order.expect(first).record(.value(3))
    }
}

@Test private func resetScopesClearOnlyRequestedState() throws {
    let service = MatchingServiceMock()
    var actions = 0

    Given(service).identify(.any).willReturn("ready")
    Perform(service).identify(.any) { _ in actions += 1 }

    #expect(try service.identify(ExternalID(rawValue: "1")) == "ready")
    resetMock(service, scopes: [.invocations])
    Verify(service, .never).identify(.any)

    // Invocation reset kept both configuration channels.
    #expect(try service.identify(ExternalID(rawValue: "2")) == "ready")
    #expect(actions == 2)

    // Action reset keeps the stub, so the call still returns normally.
    resetMock(service, scopes: [.actions])
    #expect(try service.identify(ExternalID(rawValue: "3")) == "ready")
    #expect(actions == 2)

    // Stub reset keeps history but removes the configured outcome.
    resetMock(service, scopes: [.stubs])
    #expect(throws: MockError.self) {
        try service.identify(ExternalID(rawValue: "4"))
    }

    // Omitting scopes clears invocations, stubs, and actions together.
    resetMock(service)
}
