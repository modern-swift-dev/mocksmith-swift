private extension StubOutcome {
    init(result: Result<Output, some Error>) {
        switch result {
            case let .success(output): self = .returning(output)
            case let .failure(failure): self = .throwing(failure)
        }
    }
}

/// Builder used only by retained async requirements.
public struct _MocksmithAsyncReturnStub<Arguments, Ephemeral, Output, Answer> {
    private let apply: ([StubOutcome<Arguments, Ephemeral, Output>]) -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        member: String,
        apply: @escaping ([StubOutcome<Arguments, Ephemeral, Output>]) -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.member = member
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willReturn(_ value: Output, _ values: Output...) -> _MocksmithAsyncReturnSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply(([value] + values).map(StubOutcome.returning)), answer: answerOutcome, member: member)
    }

    @discardableResult public func willSucceed() -> _MocksmithAsyncReturnSequence<Arguments, Ephemeral, Output, Answer> where Output == Void {
        .init(registration: apply([.returning(())]), answer: answerOutcome, member: member)
    }

    @discardableResult public func willAnswer(_ answer: Answer) -> _MocksmithAsyncReturnSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome, member: member)
    }

    @discardableResult public func willSuspend(
        cancellation: PendingCancellationPolicy<Never> = .ignore
    ) -> _MocksmithPendingSequence<Arguments, Ephemeral, Output, Answer> {
        let pending = PendingCall<Arguments, Output, Never>(member: member)
        let registration = apply([.suspending(on: pending, cancellation: cancellation)])
        return .init(pending: pending, registration: registration, answer: answerOutcome, member: member)
    }
}

public struct _MocksmithAsyncReturnSequence<Arguments, Ephemeral, Output, Answer> {
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>,
        member: String
    ) {
        self.registration = registration
        answerOutcome = answer
        self.member = member
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning))
        return self
    }

    @discardableResult public func thenSucceed() -> Self where Output == Void {
        registration.append([.returning(())])
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }

    @discardableResult public func thenSuspend(
        cancellation: PendingCancellationPolicy<Never> = .ignore
    ) -> _MocksmithPendingSequence<Arguments, Ephemeral, Output, Answer> {
        let pending = PendingCall<Arguments, Output, Never>(member: member)
        registration.append([.suspending(on: pending, cancellation: cancellation)])
        return .init(pending: pending, registration: registration, answer: answerOutcome, member: member)
    }
}

public struct _MocksmithPendingSequence<Arguments, Ephemeral, Output, Answer>: @unchecked Sendable {
    private let pending: PendingCall<Arguments, Output, Never>
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        pending: PendingCall<Arguments, Output, Never>,
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>,
        member: String
    ) {
        self.pending = pending
        self.registration = registration
        answerOutcome = answer
        self.member = member
    }

    public var callCount: Int {
        pending.callCount
    }

    public var arguments: [Arguments] {
        pending.arguments
    }

    /// The type-safe controller for invocations suspended by this sequence.
    public var control: PendingCall<Arguments, Output, Never> {
        pending
    }

    public func waitUntilCalled(count: Int = 1, timeout: Duration) async throws {
        try await pending.waitUntilCalled(count: count, timeout: timeout)
    }

    public func resume(returning output: sending Output) {
        pending.resume(returning: output)
    }

    public func resume() where Output == Void {
        pending.resume()
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning)); return self
    }

    @discardableResult public func thenSucceed() -> Self where Output == Void {
        registration.append([.returning(())]); return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)]); return self
    }

    @discardableResult public func thenSuspend(
        cancellation: PendingCancellationPolicy<Never> = .ignore
    ) -> _MocksmithPendingSequence<Arguments, Ephemeral, Output, Answer> {
        let pending = PendingCall<Arguments, Output, Never>(member: member)
        registration.append([.suspending(on: pending, cancellation: cancellation)])
        return .init(pending: pending, registration: registration, answer: answerOutcome, member: member)
    }
}

/// Builder used only by retained async throwing requirements.
public struct _MocksmithAsyncThrowingReturnStub<Arguments, Ephemeral, Output, Failure: Error, Answer> {
    private let apply: ([StubOutcome<Arguments, Ephemeral, Output>])
        -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        member: String,
        apply: @escaping ([StubOutcome<Arguments, Ephemeral, Output>])
            -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.member = member
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willReturn(_ value: Output, _ values: Output...) -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        makeSequence(apply(([value] + values).map(StubOutcome.returning)))
    }

    @discardableResult public func willSucceed() -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> where Output == Void {
        makeSequence(apply([.returning(())]))
    }

    @discardableResult public func willThrow(_ error: Failure, _ errors: Failure...) -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        makeSequence(apply(([error] + errors).map(StubOutcome.throwing)))
    }

    @discardableResult public func willResolve(
        _ result: Result<Output, Failure>, _ results: Result<Output, Failure>...
    ) -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        makeSequence(apply(([result] + results).map(StubOutcome.init(result:))))
    }

    @discardableResult public func willAnswer(_ answer: Answer) -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        makeSequence(apply([answerOutcome(answer)]))
    }

    @discardableResult public func willSuspend(
        cancellation: PendingCancellationPolicy<Failure> = .ignore
    ) -> _MocksmithThrowingPendingSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        let pending = PendingCall<Arguments, Output, Failure>(member: member)
        let registration = apply([.suspending(on: pending, cancellation: cancellation)])
        return .init(
            pending: pending,
            registration: registration,
            answer: answerOutcome,
            member: member
        )
    }

    private func makeSequence(
        _ registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    ) -> _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: registration, answer: answerOutcome, member: member)
    }
}

public struct _MocksmithAsyncThrowingReturnSequence<Arguments, Ephemeral, Output, Failure: Error, Answer> {
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>,
        member: String
    ) {
        self.registration = registration
        answerOutcome = answer
        self.member = member
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning))
        return self
    }

    @discardableResult public func thenSucceed() -> Self where Output == Void {
        registration.append([.returning(())])
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(StubOutcome.throwing))
        return self
    }

    @discardableResult public func thenResolve(
        _ result: Result<Output, Failure>, _ results: Result<Output, Failure>...
    ) -> Self {
        registration.append(([result] + results).map(StubOutcome.init(result:)))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }

    @discardableResult public func thenSuspend(
        cancellation: PendingCancellationPolicy<Failure> = .ignore
    ) -> _MocksmithThrowingPendingSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        let pending = PendingCall<Arguments, Output, Failure>(member: member)
        registration.append([.suspending(on: pending, cancellation: cancellation)])
        return .init(pending: pending, registration: registration, answer: answerOutcome, member: member)
    }
}

/// A sequence handle that forwards control operations to its pending call.
public struct _MocksmithThrowingPendingSequence<Arguments, Ephemeral, Output, Failure: Error, Answer>: @unchecked Sendable {
    private let pending: PendingCall<Arguments, Output, Failure>
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    private let member: String

    public init(
        pending: PendingCall<Arguments, Output, Failure>,
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>,
        member: String
    ) {
        self.pending = pending
        self.registration = registration
        answerOutcome = answer
        self.member = member
    }

    public var callCount: Int {
        pending.callCount
    }

    public var arguments: [Arguments] {
        pending.arguments
    }

    /// The type-safe controller for invocations suspended by this sequence.
    public var control: PendingCall<Arguments, Output, Failure> {
        pending
    }

    public func waitUntilCalled(count: Int = 1, timeout: Duration) async throws {
        try await pending.waitUntilCalled(count: count, timeout: timeout)
    }

    public func resume(returning output: sending Output) {
        pending.resume(returning: output)
    }

    public func resume() where Output == Void {
        pending.resume()
    }

    public func resume(throwing failure: Failure) {
        pending.resume(throwing: failure)
    }

    public func resume(with result: sending Result<Output, Failure>) {
        pending.resume(with: result)
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning))
        return self
    }

    @discardableResult public func thenSucceed() -> Self where Output == Void {
        registration.append([.returning(())])
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(StubOutcome.throwing))
        return self
    }

    @discardableResult public func thenResolve(
        _ result: Result<Output, Failure>, _ results: Result<Output, Failure>...
    ) -> Self {
        registration.append(([result] + results).map(StubOutcome.init(result:)))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }

    @discardableResult public func thenSuspend(
        cancellation: PendingCancellationPolicy<Failure> = .ignore
    ) -> _MocksmithThrowingPendingSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        let pending = PendingCall<Arguments, Output, Failure>(member: member)
        registration.append([.suspending(on: pending, cancellation: cancellation)])
        return .init(pending: pending, registration: registration, answer: answerOutcome, member: member)
    }
}

public struct _MocksmithReturnStub<Arguments, Ephemeral, Output, Answer> {
    private let apply: ([StubOutcome<Arguments, Ephemeral, Output>])
        -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>

    public init(
        apply: @escaping ([StubOutcome<Arguments, Ephemeral, Output>])
            -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willReturn(
        _ value: Output, _ values: Output...
    ) -> _MocksmithReturnSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply(([value] + values).map(StubOutcome.returning)), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(_ answer: Answer) -> _MocksmithReturnSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }

}

public struct _MocksmithReturnSequence<Arguments, Ephemeral, Output, Answer> {
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>

    public init(
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }

}

public struct _MocksmithThrowingReturnStub<
    Arguments,
    Ephemeral,
    Output,
    Failure: Error,
    Answer
> {
    private let apply: ([StubOutcome<Arguments, Ephemeral, Output>])
        -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>

    public init(
        apply: @escaping ([StubOutcome<Arguments, Ephemeral, Output>])
            -> _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willReturn(
        _ value: Output, _ values: Output...
    ) -> _MocksmithThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply(([value] + values).map(StubOutcome.returning)), answer: answerOutcome)
    }

    @discardableResult public func willThrow(
        _ error: Failure, _ errors: Failure...
    ) -> _MocksmithThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply(([error] + errors).map(StubOutcome.throwing)), answer: answerOutcome)
    }

    @discardableResult public func willResolve(
        _ result: Result<Output, Failure>, _ results: Result<Output, Failure>...
    ) -> _MocksmithThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply(([result] + results).map(StubOutcome.init(result:))), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(
        _ answer: Answer
    ) -> _MocksmithThrowingReturnSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }

}

public struct _MocksmithThrowingReturnSequence<
    Arguments,
    Ephemeral,
    Output,
    Failure: Error,
    Answer
> {
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Output>

    public init(
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenReturn(_ value: Output, _ values: Output...) -> Self {
        registration.append(([value] + values).map(StubOutcome.returning))
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(StubOutcome.throwing))
        return self
    }

    @discardableResult public func thenResolve(
        _ result: Result<Output, Failure>, _ results: Result<Output, Failure>...
    ) -> Self {
        registration.append(([result] + results).map(StubOutcome.init(result:)))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }

}

public struct _MocksmithProduceStub<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable,
    Answer
> {
    private let apply: ([TransientStubOutcome<Arguments, Ephemeral, Output>])
        -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>

    public init(
        apply: @escaping ([TransientStubOutcome<Arguments, Ephemeral, Output>])
            -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willProduce(
        _ producer: @escaping () -> Output, _ producers: (() -> Output)...
    ) -> _MocksmithProduceSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply(([producer] + producers).map(TransientStubOutcome.producing)), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(_ answer: Answer) -> _MocksmithProduceSequence<Arguments, Ephemeral, Output, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }
}

public struct _MocksmithProduceSequence<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable,
    Answer
> {
    private let registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>

    public init(
        registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenProduce(_ producer: @escaping () -> Output, _ producers: (() -> Output)...) -> Self {
        registration.append(([producer] + producers).map(TransientStubOutcome.producing))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }
}

public struct _MocksmithThrowingProduceStub<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable,
    Failure: Error,
    Answer
> {
    private let apply: ([TransientStubOutcome<Arguments, Ephemeral, Output>])
        -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>

    public init(
        apply: @escaping ([TransientStubOutcome<Arguments, Ephemeral, Output>])
            -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willProduce(
        _ producer: @escaping () -> Output, _ producers: (() -> Output)...
    ) -> _MocksmithThrowingProduceSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply(([producer] + producers).map(TransientStubOutcome.producing)), answer: answerOutcome)
    }

    @discardableResult public func willThrow(
        _ error: Failure, _ errors: Failure...
    ) -> _MocksmithThrowingProduceSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply(([error] + errors).map(TransientStubOutcome.throwing)), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(
        _ answer: Answer
    ) -> _MocksmithThrowingProduceSequence<Arguments, Ephemeral, Output, Failure, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }
}

public struct _MocksmithThrowingProduceSequence<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Output: ~Copyable,
    Failure: Error,
    Answer
> {
    private let registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>

    public init(
        registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Output>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Output>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenProduce(_ producer: @escaping () -> Output, _ producers: (() -> Output)...) -> Self {
        registration.append(([producer] + producers).map(TransientStubOutcome.producing))
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(TransientStubOutcome.throwing))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }
}

public struct _MocksmithThrowingVoidStub<
    Arguments,
    Ephemeral,
    Failure: Error,
    Answer
> {
    private let apply: ([StubOutcome<Arguments, Ephemeral, Void>])
        -> _MocksmithStubRegistration<Arguments, Ephemeral, Void>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Void>

    public init(
        apply: @escaping ([StubOutcome<Arguments, Ephemeral, Void>])
            -> _MocksmithStubRegistration<Arguments, Ephemeral, Void>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Void>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willSucceed() -> _MocksmithThrowingVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply([.returning(())]), answer: answerOutcome)
    }

    @discardableResult public func willThrow(
        _ error: Failure, _ errors: Failure...
    ) -> _MocksmithThrowingVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply(([error] + errors).map(StubOutcome.throwing)), answer: answerOutcome)
    }

    @discardableResult public func willResolve(
        _ result: Result<Void, Failure>, _ results: Result<Void, Failure>...
    ) -> _MocksmithThrowingVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply(([result] + results).map(StubOutcome.init(result:))), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(
        _ answer: Answer
    ) -> _MocksmithThrowingVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }
}

public struct _MocksmithThrowingVoidSequence<
    Arguments,
    Ephemeral,
    Failure: Error,
    Answer
> {
    private let registration: _MocksmithStubRegistration<Arguments, Ephemeral, Void>
    private let answerOutcome: (Answer) -> StubOutcome<Arguments, Ephemeral, Void>

    public init(
        registration: _MocksmithStubRegistration<Arguments, Ephemeral, Void>,
        answer: @escaping (Answer) -> StubOutcome<Arguments, Ephemeral, Void>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenSucceed() -> Self {
        registration.append([.returning(())])
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(StubOutcome.throwing))
        return self
    }

    @discardableResult public func thenResolve(
        _ result: Result<Void, Failure>, _ results: Result<Void, Failure>...
    ) -> Self {
        registration.append(([result] + results).map(StubOutcome.init(result:)))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }
}

public struct _MocksmithThrowingProduceVoidStub<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Failure: Error,
    Answer
> {
    private let apply: ([TransientStubOutcome<Arguments, Ephemeral, Void>])
        -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Void>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Void>

    public init(
        apply: @escaping ([TransientStubOutcome<Arguments, Ephemeral, Void>])
            -> _MocksmithTransientStubRegistration<Arguments, Ephemeral, Void>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Void>
    ) {
        self.apply = apply
        answerOutcome = answer
    }

    @discardableResult public func willSucceed() -> _MocksmithThrowingProduceVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply([.producing { () }]), answer: answerOutcome)
    }

    @discardableResult public func willThrow(
        _ error: Failure, _ errors: Failure...
    ) -> _MocksmithThrowingProduceVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply(([error] + errors).map(TransientStubOutcome.throwing)), answer: answerOutcome)
    }

    @discardableResult public func willAnswer(
        _ answer: Answer
    ) -> _MocksmithThrowingProduceVoidSequence<Arguments, Ephemeral, Failure, Answer> {
        .init(registration: apply([answerOutcome(answer)]), answer: answerOutcome)
    }
}

public struct _MocksmithThrowingProduceVoidSequence<
    Arguments: ~Copyable,
    Ephemeral: ~Copyable,
    Failure: Error,
    Answer
> {
    private let registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Void>
    private let answerOutcome: (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Void>

    public init(
        registration: _MocksmithTransientStubRegistration<Arguments, Ephemeral, Void>,
        answer: @escaping (Answer) -> TransientStubOutcome<Arguments, Ephemeral, Void>
    ) {
        self.registration = registration
        answerOutcome = answer
    }

    @discardableResult public func thenSucceed() -> Self {
        registration.append([.producing { () }])
        return self
    }

    @discardableResult public func thenThrow(_ error: Failure, _ errors: Failure...) -> Self {
        registration.append(([error] + errors).map(TransientStubOutcome.throwing))
        return self
    }

    @discardableResult public func thenAnswer(_ answer: Answer) -> Self {
        registration.append([answerOutcome(answer)])
        return self
    }
}
