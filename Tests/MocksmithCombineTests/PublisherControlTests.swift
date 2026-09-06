#if canImport(Combine)
    import Combine
    import Mocksmith
    import MocksmithCombine
    import Testing

    private enum PublisherFailure: Error, Equatable {
        case failed
    }

    private typealias PublisherStub = _MocksmithReturnStub<
        Void,
        Void,
        AnyPublisher<Int, PublisherFailure>,
        Never
    >

    private func publisherStub(
        _ member: MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>
    ) -> PublisherStub {
        PublisherStub(
            apply: { member.addStub(matching: { _ in true }, outcomes: $0) },
            answer: _mocksmithNoAnswer
        )
    }

    @Test @MainActor func willPublishDeliversCurrentAndSubsequentValues() throws {
        let member = MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>(name: "updates")
        let control = publisherStub(member).willPublish(current: 1)
        var values: [Int] = []
        let cancellable = try member.invoke(()).sink(
            receiveCompletion: { _ in },
            receiveValue: { values.append($0) }
        )

        control.send(2)

        #expect(values == [1, 2])
        withExtendedLifetime(cancellable) {}
    }

    @Test @MainActor func publisherControlBroadcastsToMultipleSubscribers() throws {
        let member = MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>(name: "updates")
        let control = publisherStub(member).willPublish(current: 1)
        let publisher = try member.invoke(())
        var first: [Int] = []
        var second: [Int] = []
        let firstCancellable = publisher.sink(receiveCompletion: { _ in }, receiveValue: { first.append($0) })
        let secondCancellable = publisher.sink(receiveCompletion: { _ in }, receiveValue: { second.append($0) })

        control.send(2)

        #expect(first == [1, 2])
        #expect(second == [1, 2])
        withExtendedLifetime((firstCancellable, secondCancellable)) {}
    }

    @Test @MainActor func resetDoesNotInvalidateAnAlreadyReturnedPublisher() throws {
        let member = MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>(name: "updates")
        let control = publisherStub(member).willPublish(current: 1)
        let publisher = try member.invoke(())
        var values: [Int] = []
        let cancellable = publisher.sink(receiveCompletion: { _ in }, receiveValue: { values.append($0) })

        member.reset([.stubs])
        control.send(2)

        #expect(values == [1, 2])
        withExtendedLifetime(cancellable) {}
    }

    @Test @MainActor func publisherControlSendsFailureAndCompletion() throws {
        let member = MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>(name: "updates")
        let control = publisherStub(member).willPublish(current: 1)
        var completion: Subscribers.Completion<PublisherFailure>?
        let cancellable = try member.invoke(()).sink(
            receiveCompletion: { completion = $0 },
            receiveValue: { _ in }
        )

        control.fail(.failed)

        #expect(completion == .failure(.failed))
        withExtendedLifetime(cancellable) {}
    }

    @Test @MainActor func publisherControlFinishesNormally() throws {
        let member = MockMember<Void, Void, AnyPublisher<Int, PublisherFailure>>(name: "updates")
        let control = publisherStub(member).willPublish(current: 1)
        var completion: Subscribers.Completion<PublisherFailure>?
        let cancellable = try member.invoke(()).sink(
            receiveCompletion: { completion = $0 },
            receiveValue: { _ in }
        )

        control.finish()

        #expect(completion == .finished)
        withExtendedLifetime(cancellable) {}
    }
#endif
