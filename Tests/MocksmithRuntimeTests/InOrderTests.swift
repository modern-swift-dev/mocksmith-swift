import Mocksmith
import Testing

private func makeMember(_ name: String) -> MockMember<Int, Void, Void> {
    let member = MockMember<Int, Void, Void>(name: name)
    member.addStub(matching: { _ in true }, outcomes: [.returning(())])
    return member
}

private func expect(_ member: MockMember<Int, Void, Void>, _ name: String, _ argument: Int, in order: InOrder) {
    order._append(
        source: member,
        invocations: { member.orderedInvocations },
        member: name,
        matches: { member.matchesInvocation(sequence: $0, matching: { $0 == argument }) },
        markVerified: { member._mocksmithMarkVerified(sequence: $0) }
    )
}

@Test func inOrderRetriesLaterOccurrencesOfFirstExpectation() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    try first.invoke(1)
    try second.invoke(9)
    try first.invoke(1)
    try second.invoke(2)

    let order = InOrder()
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)

    let result = order.verification()
    #expect(result.success, "\(result.message)")
    // Only the matched occurrences (positions 3 and 4) are verified.
    #expect(first._mocksmithUnverifiedInvocations.count == 1)
    #expect(second._mocksmithUnverifiedInvocations.count == 1)
}

@Test func inOrderReportsFurthestFailedAttempt() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    let third = makeMember("third")
    try first.invoke(1)
    try third.invoke(1)
    try first.invoke(1)
    try second.invoke(2)
    try first.invoke(1)

    let order = InOrder()
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)
    expect(third, "third", 3, in: order)

    let result = order.verification()
    #expect(!result.success)
    #expect(result.message == "Expected third after second, got first")
    #expect(first._mocksmithUnverifiedInvocations.count == 3)
    #expect(second._mocksmithUnverifiedInvocations.count == 1)
}

@Test func inOrderReportsSameMemberWithNonMatchingArguments() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    try first.invoke(1)
    try second.invoke(9)

    let order = InOrder()
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)

    let result = order.verification()
    #expect(!result.success)
    #expect(result.message == "Expected second after first, got second with non-matching arguments")
}

@Test func inOrderReportsMissingFollowingInvocation() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    try first.invoke(1)

    let order = InOrder()
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)

    let result = order.verification()
    #expect(!result.success)
    #expect(result.message == "Expected second after first, but no invocation followed")
}

@Test func strictInOrderRejectsInterleavedInvocations() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    try first.invoke(1)
    try second.invoke(9)
    try second.invoke(2)

    let order = InOrder(mode: .strict)
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)

    #expect(!order.verification().success)
}

@Test func relaxedInOrderSkipsInterleavedInvocations() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    let third = makeMember("third")
    try first.invoke(1)
    try second.invoke(9)
    try third.invoke(5)
    try second.invoke(2)
    try first.invoke(3)

    let order = InOrder(mode: .relaxed)
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)
    expect(first, "first", 3, in: order)

    let result = order.verification()
    #expect(result.success, "\(result.message)")
    // Skipped invocations stay unverified.
    #expect(first._mocksmithUnverifiedInvocations.isEmpty)
    #expect(second._mocksmithUnverifiedInvocations.count == 1)
    #expect(third._mocksmithUnverifiedInvocations.count == 1)
}

@Test func relaxedInOrderStillRequiresOrder() throws {
    let first = makeMember("first")
    let second = makeMember("second")
    try second.invoke(2)
    try first.invoke(1)

    let order = InOrder(mode: .relaxed)
    expect(first, "first", 1, in: order)
    expect(second, "second", 2, in: order)

    let result = order.verification()
    #expect(!result.success)
    #expect(result.message == "Expected second after first, but no matching invocation followed")
    #expect(first._mocksmithUnverifiedInvocations.count == 1)
    #expect(second._mocksmithUnverifiedInvocations.count == 1)
}
