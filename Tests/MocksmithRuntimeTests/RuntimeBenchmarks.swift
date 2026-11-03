import Dispatch
import Foundation
import Mocksmith
import Synchronization
import Testing

// Runtime hot-path timings. Skipped unless MOCKSMITH_BENCHMARK=1; they print
// numbers and never assert on wall-clock time. Run in release:
//
//   MOCKSMITH_BENCHMARK=1 swift test -c release --filter RuntimeBenchmarks

private let benchmarksEnabled = ProcessInfo.processInfo.environment["MOCKSMITH_BENCHMARK"] == "1"

/// Runs `body` `runs` times and returns the median duration.
private func median(runs: Int = 5, _ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    let durations = (0 ..< runs).map { _ in clock.measure(body) }.sorted()
    return durations[runs / 2]
}

private func microseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
}

private func report(_ name: String, _ duration: Duration, per operations: Int, unit: String = "call") {
    let total = microseconds(duration)
    let each = total / Double(operations)
    print("[benchmark] \(name): \(String(format: "%.3f", each)) µs/\(unit) (\(String(format: "%.1f", total / 1000)) ms total)")
}

final class EvaluationCounter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

@Suite(.serialized, .enabled(if: benchmarksEnabled)) struct RuntimeBenchmarks {
    private static let calls = 100_000

    private func stubbedMember(stubs: Int) -> MockMember<Int, Void, Int> {
        let member = MockMember<Int, Void, Int>(name: "value")
        for index in 0 ..< stubs {
            // Only the first stub matches every call; the rest are scanned and rejected.
            member.addStub(matching: { index == 0 || $0 < 0 }, specificity: index == 0 ? 0 : 1, outcomes: [.returning(index)])
        }
        return member
    }

    @Test func invokeWithOneStub() {
        let duration = median {
            let member = stubbedMember(stubs: 1)
            for value in 0 ..< Self.calls {
                _ = try? member.invoke(value)
            }
        }
        report("invoke, 1 stub", duration, per: Self.calls)
    }

    @Test func invokeWithFiftyStubs() {
        let duration = median {
            let member = stubbedMember(stubs: 50)
            for value in 0 ..< Self.calls {
                _ = try? member.invoke(value)
            }
        }
        report("invoke, 50 stubs", duration, per: Self.calls)
    }

    @Test func invokeConcurrently() {
        let threads = 8
        let perThread = Self.calls / threads
        let single = median {
            let member = stubbedMember(stubs: 1)
            for value in 0 ..< perThread * threads {
                _ = try? member.invoke(value)
            }
        }
        let concurrent = median {
            let member = stubbedMember(stubs: 1)
            DispatchQueue.concurrentPerform(iterations: threads) { _ in
                for value in 0 ..< perThread {
                    _ = try? member.invoke(value)
                }
            }
        }
        report("invoke, 1 stub, 1 thread", single, per: perThread * threads)
        report("invoke, 1 stub, \(threads) threads (wall)", concurrent, per: perThread * threads)
        print("[benchmark] invoke, \(threads) threads / 1 thread wall ratio: \(String(format: "%.2f", microseconds(concurrent) / microseconds(single)))")
    }

    @Test func transientInvokeWithOneStub() {
        let duration = median {
            let member = TransientMockMember<Int, Void, Int>(name: "value")
            member.addStub(matching: { _ in true }, outcomes: [.producing { 1 }])
            for value in 0 ..< Self.calls {
                _ = try? member.invoke(value)
            }
        }
        report("transient invoke, 1 stub", duration, per: Self.calls)
    }

    @Test func callHistoryAccess() {
        let recorded = 200_000
        let member = MockMember<Int, Void, Void>(name: "save")
        for value in 0 ..< recorded {
            member.record(value)
        }
        let history = member.callHistory { _ in true }
        let accesses = 20
        let count = median {
            for _ in 0 ..< accesses {
                _ = history.count
            }
        }
        let last = median {
            for _ in 0 ..< accesses {
                _ = history.lastArgument
            }
        }
        report("CallHistory.count after \(recorded) calls", count, per: accesses, unit: "access")
        report("CallHistory.lastArgument after \(recorded) calls", last, per: accesses, unit: "access")
    }

    @Test func callHistoryWaitWhileRecording() async throws {
        let recorded = 20000
        let clock = ContinuousClock()
        var durations: [Duration] = []
        var evaluations: [Int] = []
        for _ in 0 ..< 5 {
            let member = MockMember<Int, Void, Void>(name: "save")
            let counter = EvaluationCounter()
            let history = member.callHistory { _ in counter.increment(); return true }
            let start = clock.now
            let waiting = Task { try await history.waitForCount(recorded, timeout: .seconds(60)) }
            for value in 0 ..< recorded {
                member.record(value)
                if value.isMultiple(of: 10) {
                    await Task.yield()
                }
            }
            try await waiting.value
            durations.append(start.duration(to: clock.now))
            evaluations.append(counter.value)
        }
        report("record \(recorded) calls with a waitForCount waiter", durations.sorted()[2], per: recorded)
        print("[benchmark] waitForCount matcher evaluations for \(recorded) calls: median \(evaluations.sorted()[2])")
    }

    @Test func genericRegistryHit() {
        let lookups = 200_000
        let registry = GenericMockRegistry()
        let types: [ObjectIdentifier] = [ObjectIdentifier(Int.self)]
        _ = registry.member(key: "value", typeIDs: types) { MockMember<Int, Void, Int>(name: "value") }
        let duration = median {
            for _ in 0 ..< lookups {
                _ = registry.member(key: "value", typeIDs: types) { MockMember<Int, Void, Int>(name: "value") }
            }
        }
        report("GenericMockRegistry hit", duration, per: lookups, unit: "lookup")
    }

    @Test func staticRegistryHit() {
        enum Owner {}
        let lookups = 200_000
        let registry = StaticMockRegistry()
        _ = registry.member(owner: Owner.self, key: "value") { MockMember<Int, Void, Int>(name: "value") }
        let duration = median {
            for _ in 0 ..< lookups {
                _ = registry.member(owner: Owner.self, key: "value") { MockMember<Int, Void, Int>(name: "value") }
            }
        }
        report("StaticMockRegistry hit", duration, per: lookups, unit: "lookup")
    }
}
