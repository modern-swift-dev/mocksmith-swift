import Foundation

/// Controls how cancellation of a suspended mock invocation is handled.
public enum PendingCancellationPolicy<Failure: Error> {
    /// Leave the invocation pending until it is explicitly resumed.
    case ignore
    /// Remove the invocation from the pending queue and fail it with `failure`.
    case fail(with: Failure)
}

/// A FIFO controller for async mock invocations selected by `willSuspend`.
public final class PendingCall<Arguments, Output, Failure: Error>: @unchecked Sendable {
    private final class Invocation: @unchecked Sendable {
        let id: UInt64
        var continuation: CheckedContinuation<Output, any Error>?
        var cancelled = false

        init(id: UInt64) {
            self.id = id
        }
    }

    private final class Waiter: @unchecked Sendable {
        var id: UInt64?
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    private let lock = NSLock()
    private let member: String
    private var recordedArguments: [Arguments] = []
    private var pending: [Invocation] = []
    private var generation: UInt64 = 0
    private var nextInvocationID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]

    public init(member: String = "member") {
        self.member = member
    }

    /// The number of invocations accepted by this pending outcome.
    public var callCount: Int {
        lock.withLock { recordedArguments.count }
    }

    /// Arguments for every accepted invocation, in invocation order.
    public var arguments: [Arguments] {
        lock.withLock { recordedArguments }
    }

    /// Waits until this pending outcome has accepted at least `count` invocations.
    public func waitUntilCalled(count: Int = 1, timeout: Duration) async throws {
        try await callHistory.waitForCount(count, timeout: timeout)
    }

    /// Resumes the oldest pending invocation with a value.
    public func resume(returning output: sending Output) {
        let continuation = removeOldestPending()
        continuation.resume(returning: output)
    }

    /// Resumes the oldest pending `Void` invocation successfully.
    public func resume() where Output == Void {
        resume(returning: ())
    }

    /// Resumes the oldest pending invocation with an allowed failure.
    public func resume(throwing failure: Failure) {
        let continuation = removeOldestPending()
        continuation.resume(throwing: failure)
    }

    /// Resumes the oldest pending invocation with the supplied result.
    public func resume(with result: sending Result<Output, Failure>) {
        let continuation = removeOldestPending()
        switch result {
            case let .success(output):
                continuation.resume(returning: output)
            case let .failure(failure):
                continuation.resume(throwing: failure)
        }
    }

    func suspend(_ arguments: Arguments, cancellationFailure: Failure?) async throws -> Output {
        let invocation = lock.withLock { () -> Invocation in
            nextInvocationID &+= 1
            return Invocation(id: nextInvocationID)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: (failure: Failure?, waiters: [CheckedContinuation<Void, any Error>]) = lock.withLock {
                    invocation.continuation = continuation
                    let failure: Failure?
                    if invocation.cancelled, let cancellationFailure {
                        failure = cancellationFailure
                    } else {
                        pending.append(invocation)
                        failure = nil
                    }
                    recordedArguments.append(arguments)
                    generation &+= 1
                    return (failure, drainWaiters())
                }
                if let failure = result.failure {
                    continuation.resume(throwing: failure)
                }
                result.waiters.forEach { $0.resume() }
            }
        } onCancel: {
            guard let cancellationFailure else {
                return
            }
            let continuation = lock.withLock { () -> CheckedContinuation<Output, any Error>? in
                invocation.cancelled = true
                guard let index = pending.firstIndex(where: { $0.id == invocation.id }) else {
                    return nil
                }
                return pending.remove(at: index).continuation
            }
            continuation?.resume(throwing: cancellationFailure)
        }
    }

    private var callHistory: CallHistory<Arguments> {
        CallHistory(
            member: member,
            // Pending calls are never reset, so recorded arguments only grow.
            snapshot: { [self] in lock.withLock { CallHistorySnapshot(generation: generation, resets: 0, arguments: recordedArguments) } },
            matching: { _ in true },
            waitForChange: { [self] generation in try await waitForChange(after: generation) }
        )
    }

    private func removeOldestPending() -> CheckedContinuation<Output, any Error> {
        lock.withLock {
            guard !pending.isEmpty, let continuation = pending.removeFirst().continuation else {
                preconditionFailure("No pending invocation of \(member) to resume")
            }
            return continuation
        }
    }

    private func waitForChange(after observedGeneration: UInt64) async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if waiter.cancelled {
                        return .failure(CancellationError())
                    }
                    guard generation == observedGeneration else {
                        return .success(())
                    }
                    nextWaiterID &+= 1
                    waiter.id = nextWaiterID
                    waiter.continuation = continuation
                    waiters[nextWaiterID] = waiter
                    return nil
                }
                switch immediate {
                    case .success?: continuation.resume()
                    case let .failure(error)?: continuation.resume(throwing: error)
                    case nil: break
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                waiter.cancelled = true
                guard let id = waiter.id, waiters.removeValue(forKey: id) != nil else {
                    return nil
                }
                return waiter.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func drainWaiters() -> [CheckedContinuation<Void, any Error>] {
        let continuations = waiters.values.compactMap(\.continuation)
        waiters.removeAll()
        return continuations
    }
}
