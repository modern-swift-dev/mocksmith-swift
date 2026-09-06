#if canImport(Combine)
    import Combine
    import Mocksmith

    /// Controls the values and completion emitted by a publisher stub.
    public final class PublisherControl<Output, Failure: Error> {
        private let subject: CurrentValueSubject<Output, Failure>

        /// The publisher registered with the mock stub.
        public var publisher: AnyPublisher<Output, Failure> {
            subject.eraseToAnyPublisher()
        }

        public init(current: Output) {
            subject = CurrentValueSubject(current)
        }

        /// Emits a value to current subscribers and makes it the value sent to new subscribers.
        public func send(_ value: Output) {
            subject.send(value)
        }

        /// Completes the publisher.
        public func send(completion: Subscribers.Completion<Failure>) {
            subject.send(completion: completion)
        }

        /// Finishes the publisher normally.
        public func finish() {
            subject.send(completion: .finished)
        }

        /// Terminates the publisher with `error`.
        public func fail(_ error: Failure) {
            subject.send(completion: .failure(error))
        }
    }

    public extension _MocksmithReturnStub {
        /// Registers a current-value publisher and returns a controller for its emissions.
        @discardableResult func willPublish<PublisherOutput, PublisherFailure: Error>(
            current initialValue: PublisherOutput
        ) -> PublisherControl<PublisherOutput, PublisherFailure>
            where Output == AnyPublisher<PublisherOutput, PublisherFailure> {
            let control = PublisherControl<PublisherOutput, PublisherFailure>(current: initialValue)
            willReturn(control.publisher)
            return control
        }
    }
#endif
