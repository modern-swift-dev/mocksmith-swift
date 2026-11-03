import Dispatch
import Mocksmith
import Synchronization
import Testing

/// Collects the outcomes returned to concurrent callers.
private final class Results: Sendable {
    private let values = Mutex<[Int]>([])

    var counts: [Int: Int] {
        values.withLock { $0.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
    }

    func append(contentsOf newValues: [Int]) {
        values.withLock { $0.append(contentsOf: newValues) }
    }
}

private let threads = 8
private let callsPerThread = 1000
private let outcomeCount = 500

/// Every outcome before the last is returned exactly once; the last absorbs all remaining calls.
private func expectEachOutcomeOnceThenLast(_ counts: [Int: Int]) {
    let expected = Dictionary(uniqueKeysWithValues: (0 ..< outcomeCount).map {
        ($0, $0 == outcomeCount - 1 ? threads * callsPerThread - (outcomeCount - 1) : 1)
    })
    #expect(counts == expected)
}

@Test func concurrentInvocationsConsumeEachOutcomeOnce() {
    let member = MockMember<Void, Void, Int>(name: "value")
    member.addStub(matching: { _ in true }, outcomes: (0 ..< outcomeCount).map { .returning($0) })
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        results.append(contentsOf: (0 ..< callsPerThread).map { _ in (try? member.invoke(())) ?? -1 })
    }

    expectEachOutcomeOnceThenLast(results.counts)
}

@Test func concurrentTransientInvocationsConsumeEachOutcomeOnce() {
    let member = TransientMockMember<Void, Void, Int>(name: "value")
    member.addStub(matching: { _ in true }, outcomes: (0 ..< outcomeCount).map { value in .producing { value } })
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        results.append(contentsOf: (0 ..< callsPerThread).map { _ in (try? member.invoke(())) ?? -1 })
    }

    expectEachOutcomeOnceThenLast(results.counts)
}

@Test func outcomesAppendedAfterRepeatingTheLastAreReturnedInOrder() throws {
    let member = MockMember<Void, Void, Int>(name: "value")
    let registration = member.addStub(matching: { _ in true }, outcomes: [.returning(1)])
    #expect(try member.invoke(()) == 1)
    #expect(try member.invoke(()) == 1)

    registration.append([.returning(2), .returning(3)])

    #expect(try member.invoke(()) == 2)
    #expect(try member.invoke(()) == 3)
    #expect(try member.invoke(()) == 3)
}
