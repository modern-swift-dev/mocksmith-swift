import Mocksmith
import MocksmithTesting
import Testing

private struct NoncopyableSampleToken: ~Copyable {
    let rawValue: Int
}

@Mockable(.macro) private protocol NoncopyableSampleService: ~Copyable {
    /// Named noncopyable types need this marker. Requirements that spell
    /// `~Copyable` directly are selected automatically.
    @MockNoncopyable var token: NoncopyableSampleToken { get }

    @MockNoncopyable func inspect(_ token: borrowing NoncopyableSampleToken) -> Int

    @MockNoncopyable func make() -> NoncopyableSampleToken
}

@Mockable(.macro) private protocol NoncopyableInitializerSample: ~Copyable {
    @MockNoncopyable init(_ token: consuming NoncopyableSampleToken)
}

@Test private func transientMembersUseProducersWithoutRetainingArguments() {
    let service = NoncopyableSampleServiceMock()
    var inspectedValue = 0

    // Noncopyable results cannot be stored in ordinary return outcomes.
    // willProduce creates a fresh value at call time; producer sequences consume
    // in order and repeat the final producer.
    Given(service).inspect(.matching { $0.rawValue == 3 }).willProduce({ 9 }, { 10 })
    Given(service).make().willProduce { NoncopyableSampleToken(rawValue: 4) }
    Given(service).token.willProduce { NoncopyableSampleToken(rawValue: 6) }

    // Perform borrows the live argument synchronously. The transient channel
    // never retains it after the call.
    Perform(service).inspect(.any) { inspectedValue = $0.rawValue }

    #expect(service.inspect(NoncopyableSampleToken(rawValue: 3)) == 9)
    #expect(service.inspect(NoncopyableSampleToken(rawValue: 3)) == 10)
    #expect(service.inspect(NoncopyableSampleToken(rawValue: 3)) == 10)
    let made = service.make()
    let property = service.token

    #expect(made.rawValue == 4)
    #expect(property.rawValue == 6)
    #expect(inspectedValue == 3)

    // Arguments are deliberately not retained, so post-call verification is
    // count-only and exposes no Parameter matchers or argument captors.
    Verify(service, .exactly(3)).inspect()
    Verify(service, 1).make()
    Verify(service, 1).token()
}

@Test private func noncopyableInitializersRecordOnlyInvocationCount() {
    let initialized = NoncopyableInitializerSampleMock(
        NoncopyableSampleToken(rawValue: 5)
    )

    Verify(initialized, 1).initializer()
}
