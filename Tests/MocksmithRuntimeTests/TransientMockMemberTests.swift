import Mocksmith
import Testing

@Test func transientMemberUsesSpecificNewestProducerAndRepeatsLast() throws {
    let member = TransientMockMember<Int, Void, Int>(name: "transient")
    member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])
    member.addStub(matching: { $0 == 1 }, specificity: 1, outcomes: [.producing { 2 }, .producing { 3 }])
    member.addStub(matching: { $0 == 1 }, specificity: 1, outcomes: [.producing { 4 }])

    #expect(try member.invoke(1) == 4)
    #expect(try member.invoke(2) == 1)
    #expect(try member.invoke(1) == 4)
}

@Test func transientMemberRepeatsSelectedProducerSequence() throws {
    let member = TransientMockMember<Int, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])
    member.addStub(matching: { $0 == 1 }, specificity: 1, outcomes: [.producing { 2 }, .producing { 3 }])

    #expect(try member.invoke(1) == 2)
    #expect(try member.invoke(1) == 3)
    #expect(try member.invoke(1) == 3)
}

@Test func transientMemberSupportsNoncopyableArgumentsAndResults() throws {
    struct Token: ~Copyable { let value: Int }
    let member = TransientMockMember<Token, Void, Token>(name: "token")
    member.addStub(matching: { _ in true }, outcomes: [.producing { Token(value: 7) }])

    let result = try member.invoke(Token(value: 1))
    #expect(result.value == 7)
    #expect(member.verification(count: 1).success)
}

@Test func transientMemberIsCountOnlyAndResetsByScope() throws {
    let member = TransientMockMember<Int, Void, Int>(name: "count")
    var actions = 0
    member.addAction(matching: { _ in true }, action: { _ in actions += 1 })
    member.addStub(matching: { _ in true }, outcomes: [.producing { 8 }])

    #expect(try member.invoke(1) == 8)
    #expect(member.verification(count: .exactly(1)).success)
    #expect(member._mocksmithUnverifiedInvocations.isEmpty)
    #expect(member.verification(count: .exactly(1)).success)
    member.reset([.invocations])
    #expect(member.verification(count: .never).success)
    #expect(member._mocksmithUnverifiedInvocations.isEmpty)
    #expect(try member.invoke(2) == 8)
    #expect(member._mocksmithUnverifiedInvocations.count == 1)
    member.reset([.actions])
    #expect(try member.invoke(3) == 8)
    #expect(actions == 2)
    member.reset([.stubs])
    #expect(throws: MockError.unstubbed("count")) { try member.invoke(4) }
}

@Test func transientCoupledVoidActionMatchesOnceAndResetsByScope() throws {
    let member = TransientMockMember<Int, Void, Void>()
    var matches = 0
    var actions = 0
    member.addAction(
        matching: { _ in matches += 1; return true },
        outcomes: [.producing { () }],
        action: { _ in actions += 1 }
    )

    try member.invoke(1)
    #expect(matches == 1)
    #expect(actions == 1)

    member.reset([.actions])
    try member.invoke(2)
    #expect(matches == 2)
    #expect(actions == 1)

    member.reset([.stubs])
    #expect(throws: MockError.unstubbed("member")) { try member.invoke(3) }
    #expect(matches == 2)
}

@Test func transientCallbacksCanReenterChannel() throws {
    let member = TransientMockMember<Int, Void, Int>()
    member.addAction(
        matching: { _ in member.verification(count: 1).success },
        outcomes: [.producing { member.verification(count: 1).success ? 7 : 0 }],
        action: { _ in member.reset([.actions]) }
    )

    #expect(try member.invoke(1) == 7)
    member.reset([.stubs])
}

@Test func transientMemberDoesNotRetainInvocations() throws {
    final class Probe {}
    let member = TransientMockMember<Probe, Void, Void>()
    member.addStub(matching: { _ in true }, outcomes: [.producing { () }])
    weak var retained: Probe?
    do {
        let probe = Probe()
        retained = probe
        try member.invoke(probe)
    }
    #expect(retained == nil)
}

@Test func transientMemberRepeatsFinalThrownOutcome() throws {
    enum Failure: Error { case expected }
    let member = TransientMockMember<Void, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }, .throwing(Failure.expected)])

    #expect(try member.invoke(()) == 1)
    #expect(throws: Failure.expected) { try member.invoke(()) }
    #expect(throws: Failure.expected) { try member.invoke(()) }
}

@Test func transientRegistrationAppendsProducedAndThrownOutcomes() throws {
    enum Failure: Error { case expected }
    let member = TransientMockMember<Void, Void, Int>()
    let registration = member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])
    registration.append([.throwing(Failure.expected), .producing { 3 }])

    #expect(try member.invoke(()) == 1)
    #expect(throws: Failure.expected) { try member.invoke(()) }
    #expect(try member.invoke(()) == 3)
}

@Test func transientThrowingVoidBuilderBuildsMixedSequence() throws {
    enum Failure: Error { case expected }
    typealias Answer = (Int) throws -> Void
    let member = TransientMockMember<Int, Void, Void>()
    var answered = 0
    let builder = _MocksmithThrowingProduceVoidStub<Int, Void, Failure, Answer>(
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { arguments, _ in try answer(arguments) } }
    )
    builder.willSucceed()
        .thenThrow(.expected)
        .thenAnswer { answered = $0 }

    try member.invoke(1)
    #expect(throws: Failure.expected) { try member.invoke(2) }
    try member.invoke(3)
    #expect(answered == 3)
}

@Test func transientAsyncThrowingVoidBuilderBuildsMixedSequence() async throws {
    enum Failure: Error { case expected }
    typealias Answer = (Int) async throws -> Void
    let member = TransientMockMember<Int, Void, Void>()
    var answered = 0
    let builder = _MocksmithThrowingProduceVoidStub<Int, Void, Failure, Answer>(
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { arguments in try await answer(arguments) } }
    )
    builder.willSucceed()
        .thenThrow(.expected)
        .thenAnswer { answered = $0 }

    try await member.invokeAsync(1)
    await #expect(throws: Failure.expected) { try await member.invokeAsync(2) }
    try await member.invokeAsync(3)
    #expect(answered == 3)
}

@Test func transientAnswerBorrowsArgumentsAndEphemeralValues() throws {
    struct Token: ~Copyable { let value: Int }
    let member = TransientMockMember<Token, Int, Int>()
    member.addStub(
        matching: { $0.value > 0 },
        outcomes: [.answering { arguments, multiplier in arguments.value * multiplier }]
    )

    #expect(try member.invoke(Token(value: 3), ephemeral: 4) == 12)
    #expect(try member.invoke(Token(value: 2), ephemeral: 5) == 10)
}

@Test func transientAsyncAnswerUsesBorrowedArguments() async throws {
    struct Token: ~Copyable { let value: Int }
    let member = TransientMockMember<Token, Void, Int>()
    member.addStub(
        matching: { _ in true },
        outcomes: [.answering { arguments async in
            await Task.yield()
            return arguments.value * 2
        }]
    )

    #expect(try await member.invokeAsync(Token(value: 3)) == 6)
}

@Test func transientRegistriesSeparateSpecializationsAndReset() throws {
    enum Owner {}
    let staticRegistry = StaticMockRegistry()
    let genericRegistry = GenericMockRegistry()
    let strings: TransientMockMember<String, Void, String> = staticRegistry.member(owner: Owner.self, key: "echo", types: [String.self]) { .init(name: "echo") }
    let integers: TransientMockMember<Int, Void, Int> = genericRegistry.member(key: "echo", types: [Int.self]) { .init(name: "echo") }
    strings.addStub(matching: { _ in true }, outcomes: [.producing { "text" }])
    integers.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])

    #expect(try strings.invoke("input") == "text")
    #expect(try integers.invoke(0) == 1)
    staticRegistry.reset(owner: Owner.self, scopes: [.stubs])
    genericRegistry.reset([.stubs])
    #expect(throws: MockError.unstubbed("echo")) { try strings.invoke("input") }
    #expect(throws: MockError.unstubbed("echo")) { try integers.invoke(0) }
}

@Test func transientRegistryKeysNoncopyableGenericSpecializationsByMetatypeIdentifier() throws {
    struct First: ~Copyable {}
    struct Second: ~Copyable {}
    let registry = GenericMockRegistry()

    func member<Value: ~Copyable>(for _: Value.Type) -> TransientMockMember<Value, Void, Int> {
        registry.member(key: "generic", typeIDs: [ObjectIdentifier(Value.self)]) { .init(name: "generic") }
    }

    let first = member(for: First.self)
    let second = member(for: Second.self)
    first.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])
    second.addStub(matching: { _ in true }, outcomes: [.producing { 2 }])
    #expect(try first.invoke(First()) == 1)
    #expect(try second.invoke(Second()) == 2)
}

@Test func transientStaticRegistryReleasesRemovedChannel() {
    enum Owner {}
    let registry = StaticMockRegistry()
    weak var retained: AnyObject?
    do {
        let member: TransientMockMember<Int, Void, Int> = registry.member(owner: Owner.self, key: "value") { .init() }
        retained = member
    }
    registry.remove(owner: Owner.self, key: "value")
    #expect(retained == nil)
}

@Test func transientMemberSupportsConcurrentCalls() async throws {
    let member = TransientMockMember<Int, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])

    try await withThrowingTaskGroup(of: Int.self) { group in
        for value in 0 ..< 100 {
            group.addTask { try member.invoke(value) }
        }
        for try await result in group {
            #expect(result == 1)
        }
    }
    #expect(member.invocationCount == 100)
}

@Test func noncopyableTransientMemberRecordsConcurrentCallsInSequenceOrder() async throws {
    struct Token: ~Copyable { let value: Int }
    let member = TransientMockMember<Token, Void, Token>(name: "token")
    member.addStub(matching: { $0.value >= 0 }, outcomes: [.producing { Token(value: 7) }])

    try await withThrowingTaskGroup(of: Int.self) { group in
        for value in 0 ..< 100 {
            group.addTask { try member.invoke(Token(value: value)).value }
        }
        for try await result in group {
            #expect(result == 7)
        }
    }
    let sequences = member.orderedInvocations.map(\.sequence)
    #expect(sequences.count == 100)
    #expect(sequences == sequences.sorted())
    #expect(member.verification(count: 100).success)
}

@Test func transientMemberSupportsConcurrentConfiguration() async throws {
    let member = TransientMockMember<Int, Void, Int>()
    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 100 {
            group.addTask {
                member.addStub(matching: { $0 == value }, specificity: 1, outcomes: [.producing { value }])
            }
        }
    }
    for value in 0 ..< 100 {
        #expect(try member.invoke(value) == value)
    }
}

@Test func memberForwardsNonescapingClosureWithoutRecordingOrRetainingIt() {
    protocol Service { func call(id: Int, completion: () -> Void) -> Int }
    final class ServiceMock: Service {
        let member = MockMember<Int, () -> Void, Int>(name: "call")

        func call(id: Int, completion: () -> Void) -> Int {
            do {
                return try withoutActuallyEscaping(completion) {
                    try member.invoke(id, ephemeral: $0)
                }
            } catch {
                preconditionFailure("Unexpected unstubbed call: \(error)")
            }
        }
    }
    final class Probe {}

    let mock = ServiceMock()
    mock.member.addStub(
        matching: { $0 == 1 },
        specificity: 1,
        outcomes: [.answering { _, completion in completion(); return 7 }]
    )
    var selected: [Int] = []
    mock.member.addAction(matching: { _ in true }, action: { _, _ in selected.append(1) })
    mock.member.addAction(matching: { $0 == 1 }, specificity: 1, action: { _, _ in selected.append(2) })
    mock.member.addAction(matching: { $0 == 1 }, specificity: 1, action: { _, _ in selected.append(3) })

    weak var retained: Probe?
    do {
        let probe = Probe()
        retained = probe
        #expect(mock.call(id: 1) { _ = probe } == 7)
    }
    #expect(selected == [3])
    #expect(retained == nil)
    #expect(mock.member.verification(matching: { $0 == 1 }, count: 1).success)

    mock.member.reset([.actions])
    #expect(mock.call(id: 1) {} == 7)
    #expect(selected == [3])
}
