import Foundation

public struct _MocksmithInvocation: Sendable, Equatable {
    public let sequence: UInt64
    public let member: String

    public init(sequence: UInt64, member: String) {
        self.sequence = sequence
        self.member = member
    }
}

private enum InvocationSequence {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var value: UInt64 = 0

    static func next() -> UInt64 {
        lock.withLock {
            precondition(value < .max, "Mock invocation sequence exhausted")
            value += 1
            return value
        }
    }
}

func nextMockInvocationSequence() -> UInt64 {
    InvocationSequence.next()
}

/// How later in-order expectations relate to the invocation matched before them.
public enum InOrderMode: Sendable {
    /// Each later expectation must match the immediate next participating invocation.
    case strict
    /// Later expectations may skip participating invocations that don't match them.
    case relaxed
}

public final class InOrder {
    private enum SourceID: Hashable {
        case instance(ObjectIdentifier)
        case type(ObjectIdentifier)
    }

    private struct Expectation {
        let member: String
        let matches: (UInt64) -> Bool
        let markVerified: (UInt64) -> Void
    }

    private var sources: [SourceID: () -> [_MocksmithInvocation]] = [:]
    private var expectations: [Expectation] = []
    private let mode: InOrderMode

    public init(mode: InOrderMode = .strict) {
        self.mode = mode
    }

    public func _append(
        source: AnyObject,
        invocations: @escaping () -> [_MocksmithInvocation],
        member: String,
        matches: @escaping (UInt64) -> Bool,
        markVerified: @escaping (UInt64) -> Void = { _ in }
    ) {
        sources[.instance(ObjectIdentifier(source))] = invocations
        expectations.append(.init(member: member, matches: matches, markVerified: markVerified))
    }

    public func _append(
        sourceType: Any.Type,
        invocations: @escaping () -> [_MocksmithInvocation],
        member: String,
        matches: @escaping (UInt64) -> Bool,
        markVerified: @escaping (UInt64) -> Void = { _ in }
    ) {
        sources[.type(ObjectIdentifier(sourceType))] = invocations
        expectations.append(.init(member: member, matches: matches, markVerified: markVerified))
    }

    public func verification() -> VerificationResult {
        guard let first = expectations.first else {
            return .init(success: false, message: "In-order verification needs at least one expected invocation")
        }

        let invocations = sources.values.flatMap { $0() }.sorted { $0.sequence < $1.sequence }
        let starts = invocations.indices.filter { first.matches(invocations[$0].sequence) }
        guard !starts.isEmpty else {
            return .init(success: false, message: "Expected first in-order invocation \(first.member), but it was not called")
        }

        // The first expectation may match anywhere, so try every occurrence as a start and keep
        // the failure that got furthest (earliest on ties) to explain why none matched. Relaxed
        // matching picks the earliest match at each step, so a later start can't do better.
        let candidates = mode == .strict ? starts[...] : starts.prefix(1)
        var bestFailure = (matchedCount: 0, message: "")
        for start in candidates {
            switch attempt(from: start, in: invocations) {
                case let .matched(matched):
                    matched.forEach { $0.expectation.markVerified($0.sequence) }
                    return .init(success: true, message: "Verified \(expectations.count) invocations in order")
                case let .failed(matchedCount, message):
                    if matchedCount > bestFailure.matchedCount {
                        bestFailure = (matchedCount, message)
                    }
            }
        }
        return .init(success: false, message: bestFailure.message)
    }

    private enum Attempt {
        case matched([(expectation: Expectation, sequence: UInt64)])
        case failed(matchedCount: Int, message: String)
    }

    private func attempt(from start: Int, in invocations: [_MocksmithInvocation]) -> Attempt {
        var index = start
        var matched = [(expectation: expectations[0], sequence: invocations[start].sequence)]

        for expectation in expectations.dropFirst() {
            let previous = invocations[index]
            switch mode {
                case .strict:
                    index += 1
                    guard index < invocations.endIndex else {
                        return .failed(
                            matchedCount: matched.count,
                            message: "Expected \(expectation.member) after \(previous.member), but no invocation followed"
                        )
                    }
                    let actual = invocations[index]
                    guard expectation.matches(actual.sequence) else {
                        let got = actual.member == expectation.member ? "\(actual.member) with non-matching arguments" : actual.member
                        return .failed(
                            matchedCount: matched.count,
                            message: "Expected \(expectation.member) after \(previous.member), got \(got)"
                        )
                    }
                case .relaxed:
                    guard let next = invocations[(index + 1)...].firstIndex(where: { expectation.matches($0.sequence) }) else {
                        return .failed(
                            matchedCount: matched.count,
                            message: "Expected \(expectation.member) after \(previous.member), but no matching invocation followed"
                        )
                    }
                    index = next
            }
            matched.append((expectation, invocations[index].sequence))
        }
        return .matched(matched)
    }
}

public protocol InOrderMock: Mock {
    associatedtype OrderExpect
    func orderExpectations(in order: InOrder) -> OrderExpect
}

public protocol InOrderStaticMock: StaticMock {
    associatedtype StaticOrderExpect
    static func orderExpectations(in order: InOrder) -> StaticOrderExpect
}

public extension InOrder {
    func expect<M: InOrderMock>(_ mock: M) -> M.OrderExpect {
        mock.orderExpectations(in: self)
    }

    func expect<M: InOrderStaticMock>(_ type: M.Type) -> M.StaticOrderExpect {
        type.orderExpectations(in: self)
    }
}
