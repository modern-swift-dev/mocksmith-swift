import Mocksmith
import Testing

@Test func memberUsesSpecificNewestStubAndRepeatsLastOutcome() throws {
    let member = MockMember<String, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    member.addStub(matching: { $0 == "x" }, specificity: 1, outcomes: [.returning(2), .returning(3)])
    member.addStub(matching: { $0 == "x" }, specificity: 1, outcomes: [.returning(4)])
    #expect(try member.invoke("x") == 4)
    #expect(try member.invoke("other") == 1)
}

@Test func unstubbedFallbackDoesNotMaskConfiguredErrors() throws {
    let member = MockMember<Void, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.throwing(MockError.unstubbed("configured"))])

    #expect(throws: MockError.unstubbed("configured")) {
        try member.invoke((), unstubbed: { 1 })
    }
}

@Test func transientUnstubbedFallbackRunsAfterRecording() throws {
    let member = TransientMockMember<Void, Void, Void>()
    try member.invoke((), unstubbed: { () })
    #expect(member.invocationCount == 1)
}

@Test func moreSpecificStubBeatsNewerRegistration() throws {
    let member = MockMember<String, Void, Int>()
    member.addStub(matching: { $0 == "x" }, specificity: 1, outcomes: [.returning(1)])
    member.addStub(matching: { _ in true }, outcomes: [.returning(2)])
    #expect(try member.invoke("x") == 1)
}

@Test func mixedOutcomesConsumeInOrderAndRepeatLast() throws {
    enum Failure: Error { case expected }
    let member = MockMember<Void, Void, Int>()
    member.addStub(
        matching: { _ in true },
        outcomes: [.returning(1), .throwing(Failure.expected), .returning(3)]
    )
    #expect(try member.invoke(()) == 1)
    #expect(throws: Failure.expected) { try member.invoke(()) }
    #expect(try member.invoke(()) == 3)
    #expect(try member.invoke(()) == 3)
}

@Test func appendableStubRegistrationBuildsMixedOutcomeSequence() throws {
    enum Failure: Error { case expected }
    let member = MockMember<Void, Void, Int>(name: "value")
    let registration = member.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    registration.append([.throwing(Failure.expected), .returning(3)])

    #expect(try member.invoke(()) == 1)
    #expect(throws: Failure.expected) { try member.invoke(()) }
    #expect(try member.invoke(()) == 3)
    #expect(try member.invoke(()) == 3)
}

@Test func answersUseArgumentsAndMixWithFixedOutcomes() throws {
    enum Failure: Error { case expected }
    let member = MockMember<Int, Void, Int>()
    member.addStub(
        matching: { _ in true },
        outcomes: [
            .answering { arguments, _ in arguments * 2 },
            .returning(10),
            .throwing(Failure.expected),
            .answering { arguments, _ in arguments + 1 }
        ]
    )

    #expect(try member.invoke(2) == 4)
    #expect(try member.invoke(3) == 10)
    #expect(throws: Failure.expected) { try member.invoke(4) }
    #expect(try member.invoke(5) == 6)
    #expect(try member.invoke(6) == 7)
}

@Test func asyncAnswersSuspendOutsideMemberLock() async throws {
    let member = MockMember<Int, Void, Int>()
    member.addStub(
        matching: { _ in true },
        outcomes: [.answering { arguments async in
            #expect(member.invocationCount(matching: { _ in true }) == 1)
            await Task.yield()
            return arguments * 2
        }]
    )

    #expect(try await member.invokeAsync(4) == 8)
}

@Test func asyncInvocationRunsEphemeralActionBeforeAnswer() async throws {
    let member = MockMember<Int, Int, Int>()
    var actionValue = 0
    member.addAction(matching: { _ in true }, action: { arguments, ephemeral in
        actionValue = arguments + ephemeral
    })
    member.addStub(
        matching: { _ in true },
        outcomes: [.answering { arguments async in
            #expect(actionValue == 7)
            await Task.yield()
            return arguments * 2
        }]
    )

    #expect(try await member.invokeAsync(4, ephemeral: 3) == 8)
}

@Test func answerBuildersAppendMixedSequence() throws {
    enum Failure: Error { case expected }
    typealias Answer = (Int) throws -> Int
    let member = MockMember<Int, Void, Int>()
    let builder = _MocksmithThrowingReturnStub<Int, Void, Int, Failure, Answer>(
        apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
        answer: { answer in .answering { arguments, _ in try answer(arguments) } }
    )
    builder.willAnswer { arguments in arguments }
        .thenReturn(2)
        .thenThrow(.expected)
        .thenAnswer { arguments in arguments * 2 }

    #expect(try member.invoke(1) == 1)
    #expect(try member.invoke(1) == 2)
    #expect(throws: Failure.expected) { try member.invoke(1) }
    #expect(try member.invoke(3) == 6)
}

@Test func inOrderUsesStrictAdjacencyAcrossSources() throws {
    let first = MockMember<Int, Void, Void>(name: "first")
    let second = MockMember<Int, Void, Void>(name: "second")
    first.addStub(matching: { _ in true }, outcomes: [.returning(())])
    second.addStub(matching: { _ in true }, outcomes: [.returning(())])

    try first.invoke(1)
    try second.invoke(2)
    try first.invoke(3)

    let success = InOrder()
    success._append(
        source: first,
        invocations: { first.orderedInvocations },
        member: "first",
        matches: { first.matchesInvocation(sequence: $0, matching: { $0 == 1 }) },
        markVerified: { first._mocksmithMarkVerified(sequence: $0) }
    )
    success._append(
        source: second,
        invocations: { second.orderedInvocations },
        member: "second",
        matches: { second.matchesInvocation(sequence: $0, matching: { $0 == 2 }) },
        markVerified: { second._mocksmithMarkVerified(sequence: $0) }
    )
    success._append(
        source: first,
        invocations: { first.orderedInvocations },
        member: "first",
        matches: { first.matchesInvocation(sequence: $0, matching: { $0 == 3 }) },
        markVerified: { first._mocksmithMarkVerified(sequence: $0) }
    )
    #expect(success.verification().success)
    #expect(first._mocksmithUnverifiedInvocations.isEmpty)
    #expect(second._mocksmithUnverifiedInvocations.isEmpty)

    first.reset([.invocations])
    second.reset([.invocations])
    try first.invoke(1)
    try second.invoke(2)
    try first.invoke(3)

    let failure = InOrder()
    failure._append(
        source: first,
        invocations: { first.orderedInvocations },
        member: "first",
        matches: { first.matchesInvocation(sequence: $0, matching: { $0 == 1 }) },
        markVerified: { first._mocksmithMarkVerified(sequence: $0) }
    )
    failure._append(
        source: first,
        invocations: { first.orderedInvocations },
        member: "first",
        matches: { first.matchesInvocation(sequence: $0, matching: { $0 == 3 }) },
        markVerified: { first._mocksmithMarkVerified(sequence: $0) }
    )
    failure._append(
        source: second,
        invocations: { second.orderedInvocations },
        member: "second",
        matches: { second.matchesInvocation(sequence: $0, matching: { $0 == 2 }) },
        markVerified: { second._mocksmithMarkVerified(sequence: $0) }
    )
    let result = failure.verification()
    #expect(!result.success)
    #expect(result.message.contains("got second"))
    #expect(first._mocksmithUnverifiedInvocations.count == 2)
    #expect(second._mocksmithUnverifiedInvocations.count == 1)
}

@Test func verificationMarksOnlySuccessfulMatchingSnapshot() {
    let member = MockMember<Int, Void, Void>(name: "load(_:)")
    member.record(1)
    member.record(2)
    member.record(1)

    #expect(!member.verification(matching: { $0 == 1 }, count: 3).success)
    #expect(member._mocksmithUnverifiedInvocations.count == 3)
    #expect(member.verification(matching: { $0 == 1 }, count: 2).success)
    #expect(member._mocksmithUnverifiedInvocations.count == 1)
    #expect(member.verification(matching: { $0 == 1 }, count: 2).success)
    #expect(member.invocationCount(matching: { $0 == 1 }) == 2)

    member.reset([.invocations])
    #expect(member._mocksmithUnverifiedInvocations.isEmpty)
    member.record(1)
    #expect(member._mocksmithUnverifiedInvocations.count == 1)
}

@Test func verificationEvaluatesMatcherOutsideLockAndUsesSnapshot() {
    let member = MockMember<Int, Void, Void>(name: "load(_:)")
    member.record(1)
    var recorded = false

    let result = member.verification(matching: { _ in
        if !recorded {
            recorded = true
            member.record(2)
        }
        return true
    }, count: 1)

    #expect(result.success)
    #expect(member._mocksmithUnverifiedInvocations.count == 1)
}

@Test func actionAndCaptorWorkWithoutLeakingResetState() throws {
    let member = MockMember<Int, Void, Int>()
    let captor = ArgumentCaptor<Int>()
    let parameter = Parameter<Int>.capturing(captor)
    member.addAction(matching: parameter.matches, specificity: parameter.specificity, action: { _ in })
    member.addStub(matching: { _ in true }, outcomes: [.returning(8)])
    #expect(try member.invoke(4) == 8)
    #expect(captor.values == [4])
    #expect(member.verification(matching: { $0 == 4 }, count: 1).success)
    member.reset([.invocations])
    #expect(member.verification(matching: { _ in true }, count: .never).success)
}

@Test func coupledVoidActionEvaluatesMatcherOnceAndResetsByScope() throws {
    let member = MockMember<Int, Void, Void>()
    let captor = ArgumentCaptor<Int>()
    let parameter = Parameter<Int>.capturing(captor)
    var actions = 0
    member.addAction(
        matching: parameter.matches,
        specificity: parameter.specificity,
        outcomes: [.returning(())],
        action: { _ in actions += 1 }
    )

    try member.invoke(1)
    #expect(captor.values == [1])
    #expect(actions == 1)

    member.reset([.actions])
    try member.invoke(2)
    #expect(captor.values == [1, 2])
    #expect(actions == 1)

    member.reset([.stubs])
    #expect(throws: MockError.unstubbed("member")) { try member.invoke(3) }
}

@Test func missingStubThrowsFrameworkError() {
    let member = MockMember<Void, Void, Void>(name: "work")
    #expect(throws: MockError.unstubbed("work")) { try member.invoke(()) }
}

@Test func recordAddsInvocationWithoutNeedingStub() {
    let member = MockMember<Int, Void, Void>(name: "init")
    member.record(42)
    #expect(member.verification(matching: { $0 == 42 }, count: 1).success)
}

@Test func everyCountFormMatchesExpectedInvocations() throws {
    let member = MockMember<Void, Void, Void>()
    member.addStub(matching: { _ in true }, outcomes: [.returning(())])
    try member.invoke(())
    try member.invoke(())

    #expect(member.verification(matching: { _ in true }, count: .exactly(2)).success)
    #expect(member.verification(matching: { _ in true }, count: .atLeast(1)).success)
    #expect(member.verification(matching: { _ in true }, count: .atMost(2)).success)
    #expect(member.verification(matching: { _ in true }, count: .between(1, 3)).success)
    #expect(member.verification(matching: { _ in true }, count: .between(1 ... 2)).success)
    #expect(!member.verification(matching: { _ in true }, count: .never).success)
}

@Test func scopedResetOnlyClearsRequestedState() throws {
    let member = MockMember<Int, Void, Int>()
    var actions = 0
    member.addAction(matching: { _ in true }, action: { _ in actions += 1 })
    member.addStub(matching: { _ in true }, outcomes: [.returning(1)])

    #expect(try member.invoke(1) == 1)
    member.reset([.invocations])
    #expect(member.invocationCount(matching: { _ in true }) == 0)
    #expect(try member.invoke(2) == 1)
    #expect(actions == 2)

    member.reset([.actions])
    #expect(try member.invoke(3) == 1)
    #expect(actions == 2)

    member.reset([.stubs])
    #expect(throws: MockError.unstubbed("member")) { try member.invoke(4) }
}

@Test func staticRegistryReusesTypedMemberAndResetsIt() throws {
    enum Owner {}
    let registry = StaticMockRegistry()
    let first: MockMember<Void, Void, Int> = registry.member(owner: Owner.self, key: "value") { .init(name: "value") }
    first.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    let second: MockMember<Void, Void, Int> = registry.member(owner: Owner.self, key: "value") { .init(name: "other") }
    #expect(first === second)
    #expect(try second.invoke(()) == 1)
    registry.reset(owner: Owner.self, scopes: [.stubs])
    #expect(throws: MockError.unstubbed("value")) { try second.invoke(()) }
}

@Test func staticRegistrySeparatesGenericSpecializations() throws {
    enum Owner {}
    let registry = StaticMockRegistry()
    let strings: MockMember<String, Void, String> = registry.member(owner: Owner.self, key: "echo", types: [String.self]) { .init(name: "echo") }
    let integers: MockMember<Int, Void, Int> = registry.member(owner: Owner.self, key: "echo", types: [Int.self]) { .init(name: "echo") }
    strings.addStub(matching: { _ in true }, outcomes: [.returning("text")])
    integers.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    #expect(try strings.invoke("input") == "text")
    #expect(try integers.invoke(0) == 1)
    registry.reset(owner: Owner.self, scopes: [.stubs])
    #expect(throws: MockError.unstubbed("echo")) { try strings.invoke("input") }
    #expect(throws: MockError.unstubbed("echo")) { try integers.invoke(0) }
}

@Test func genericRegistrySeparatesTypeSpecializations() throws {
    let registry = GenericMockRegistry()
    let strings: MockMember<String, Void, String> = registry.member(key: "echo", types: [String.self]) { .init(name: "echo") }
    let integers: MockMember<Int, Void, Int> = registry.member(key: "echo", types: [Int.self]) { .init(name: "echo") }
    strings.addStub(matching: { _ in true }, outcomes: [.returning("text")])
    integers.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    #expect(try strings.invoke("input") == "text")
    #expect(try integers.invoke(0) == 1)
}

@Test func registriesAggregateUnverifiedInvocationsInSequenceOrder() {
    enum Owner {}
    enum OtherOwner {}
    let staticRegistry = StaticMockRegistry()
    let load: MockMember<Int, Void, Void> = staticRegistry.member(owner: Owner.self, key: "load") { .init(name: "load(_:)") }
    let save: MockMember<Int, Void, Void> = staticRegistry.member(owner: Owner.self, key: "save") { .init(name: "save(_:)") }
    let other: MockMember<Void, Void, Void> = staticRegistry.member(owner: OtherOwner.self, key: "other") { .init(name: "other") }
    load.record(1)
    other.record(())
    save.record(2)
    load.record(3)

    let staticResult = _mocksmithNoMoreInteractionsResult(staticRegistry.unverifiedInvocations(owner: Owner.self))
    #expect(staticResult.message == "Unverified interactions: load(*:) ×2, save(*:) ×1")

    let genericRegistry = GenericMockRegistry()
    let strings: MockMember<String, Void, Void> = genericRegistry.member(key: "load", types: [String.self]) { .init(name: "load(_:)") }
    let integers: TransientMockMember<Int, Void, Void> = genericRegistry.member(key: "save", types: [Int.self]) { .init(name: "save(_:)") }
    strings.record("value")
    integers.record()
    #expect(genericRegistry.unverifiedInvocations.count == 2)
}

@Test func memberSupportsConcurrentInvocation() async throws {
    let member = MockMember<Int, Void, Int>()
    member.addStub(matching: { _ in true }, outcomes: [.returning(1)])

    try await withThrowingTaskGroup(of: Int.self) { group in
        for value in 0 ..< 100 {
            group.addTask { try member.invoke(value) }
        }
        for try await result in group {
            #expect(result == 1)
        }
    }

    #expect(member.invocationCount(matching: { _ in true }) == 100)
}

@Test func memberSupportsConcurrentConfiguration() async throws {
    let member = MockMember<Int, Void, Int>()

    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 100 {
            group.addTask {
                member.addStub(matching: { $0 == value }, specificity: 1, outcomes: [.returning(value)])
            }
        }
    }

    for value in 0 ..< 100 {
        #expect(try member.invoke(value) == value)
    }
}

@Test func invocationRunsMatchersActionsAndAnswersOutsideMemberLock() throws {
    let member = MockMember<Int, Void, Int>()
    let transient = TransientMockMember<Int, Void, Int>()
    member.addAction(
        matching: { _ in member.invocationCount(matching: { _ in true }) > 0 },
        outcomes: [.returning(0)],
        action: { _ in member.record(-1) }
    )
    member.addStub(matching: { _ in member.invocationCount(matching: { _ in true }) > 0 }, specificity: 1, outcomes: [.answering { arguments, _ in
        member.invocationCount(matching: { $0 == arguments })
    }])
    transient.addAction(matching: { _ in transient.invocationCount > 0 }, action: { _ in transient.record() })
    transient.addStub(matching: { _ in transient.invocationCount > 0 }, outcomes: [.answering { _, _ in transient.invocationCount }])

    #expect(try member.invoke(7) == 1)
    #expect(member.invocationCount(matching: { $0 == -1 }) == 1)
    #expect(try transient.invoke(7) == 2)
}

@Test func concurrentRecordingKeepsSequencesOrderedAndLookupsExact() async {
    let member = MockMember<Int, Void, Void>(name: "save")
    let transient = TransientMockMember<Int, Void, Void>(name: "send")
    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 200 {
            group.addTask {
                member.record(value)
                transient.record()
            }
        }
    }

    for invocations in [member.orderedInvocations, transient.orderedInvocations] {
        #expect(invocations.count == 200)
        #expect(zip(invocations, invocations.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    }
    for invocation in member.orderedInvocations {
        #expect(member.matchesInvocation(sequence: invocation.sequence, matching: { _ in true }))
        #expect(!member.matchesInvocation(sequence: invocation.sequence + 1_000_000, matching: { _ in true }))
    }
    for invocation in transient.orderedInvocations {
        #expect(transient.matchesInvocation(sequence: invocation.sequence))
    }
    #expect(!transient.matchesInvocation(sequence: 0))

    let sequences = member.orderedInvocations.map(\.sequence)
    let values = sequences.compactMap { sequence in
        (0 ..< 200).first { value in member.matchesInvocation(sequence: sequence, matching: { $0 == value }) }
    }
    #expect(Set(values) == Set(0 ..< 200))
}

@Test func memberRecordsConcurrentInvocationsInSequenceOrder() async throws {
    let member = MockMember<Int, Void, Int>(name: "load(_:)")
    member.addStub(matching: { _ in true }, outcomes: [.answering { arguments, _ in arguments * 2 }])

    try await withThrowingTaskGroup(of: Void.self) { group in
        for task in 0 ..< 8 {
            group.addTask {
                for value in task * 100 ..< (task + 1) * 100 {
                    let output = try member.invoke(value)
                    #expect(output == value * 2)
                }
            }
            group.addTask {
                member.addAction(matching: { $0 == task }, action: { _ in })
            }
        }
        try await group.waitForAll()
    }

    let invocations = member.orderedInvocations
    #expect(invocations.count == 800)
    #expect(invocations.map(\.sequence) == invocations.map(\.sequence).sorted())
    #expect(invocations.allSatisfy { member.matchesInvocation(sequence: $0.sequence, matching: { _ in true }) })
    #expect(member.verification(matching: { $0 < 100 }, count: 100).success)
}
