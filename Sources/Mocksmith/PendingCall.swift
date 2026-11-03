import Foundation
import Synchronization

/// Controls how cancellation of a suspended mock invocation is handled.
public enum PendingCancellationPolicy<Failure: Error> {
    /// Leave the invocation pending until it is explicitly resumed.
    case ignore
    /// Remove the invocation from the pending queue and fail it with `failure`.
    case fail(with: Failure)
}

/// A FIFO controller for async mock invocations selected by `willSuspend`.
public final class PendingCall<Arguments, Output, Failure: Error>: Sendable {
    private struct State {
        // Sound: the mutex guards every access; handing recorded arguments to the test that reads them
        // is the mock's documented contract, so region checking is waived for these user values.
        nonisolated(unsafe) var recordedArguments: [Arguments] = []
        var pending: [(id: UInt64, continuation: CheckedContinuation<Output, any Error>)] = []
        var generation: UInt64 = 0
        var nextInvocationID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())
    private let member: String

    public init(member: String = "member") {
        self.member = member
    }

    /// The number of invocations accepted by this pending outcome.
    public var callCount: Int {
        state.withLock { $0.recordedArguments.count }
    }

    /// Arguments for every accepted invocation, in invocation order.
    public var arguments: [Arguments] {
        state.withLock { $0.recordedArguments }
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
        let id = state.withLock { state in
            state.nextInvocationID &+= 1
            return state.nextInvocationID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (failure, waiters) = state.withLock { state in
                    // Cancellation is flagged before `onCancel` runs, and both sides check under the
                    // lock, so a cancelled invocation is either never queued or removed by `onCancel`.
                    let failure = Task.isCancelled ? cancellationFailure : nil
                    if failure == nil {
                        state.pending.append((id, continuation))
                    }
                    state.recordedArguments.append(arguments)
                    state.generation &+= 1
                    return (failure, Self.drainWaiters(&state))
                }
                if let failure {
                    continuation.resume(throwing: failure)
                }
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            guard let cancellationFailure else {
                return
            }
            let continuation = state.withLock { state in
                state.pending.firstIndex { $0.id == id }.map { state.pending.remove(at: $0).continuation }
            }
            continuation?.resume(throwing: cancellationFailure)
        }
    }

    private var callHistory: CallHistory<Arguments> {
        CallHistory(
            member: member,
            // Pending calls are never reset, so recorded arguments only grow.
            snapshot: { [self] in
                state.withLock { CallHistorySnapshot(generation: $0.generation, resets: 0, arguments: $0.recordedArguments) }
            },
            matching: { _ in true },
            waitForChange: { [self] generation in try await waitForChange(after: generation) }
        )
    }

    private func removeOldestPending() -> CheckedContinuation<Output, any Error> {
        state.withLock { state in
            guard !state.pending.isEmpty else {
                preconditionFailure("No pending invocation of \(member) to resume")
            }
            return state.pending.removeFirst().continuation
        }
    }

    private func waitForChange(after observedGeneration: UInt64) async throws {
        let id = state.withLock { state in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    // Cancellation is flagged before `onCancel` runs, and both sides check under the
                    // lock, so a cancelled waiter is either never registered or removed by `onCancel`.
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard state.generation == observedGeneration else {
                        return .success(())
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                switch immediate {
                    case .success?: continuation.resume()
                    case let .failure(error)?: continuation.resume(throwing: error)
                    case nil: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { $0.waiters.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func drainWaiters(_ state: inout State) -> [CheckedContinuation<Void, any Error>] {
        let continuations = Array(state.waiters.values)
        state.waiters.removeAll()
        return continuations
    }
}
