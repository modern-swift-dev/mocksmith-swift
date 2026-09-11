import Mocksmith
import MocksmithTesting
import Testing

private enum AsyncSampleFailure: Error, Equatable {
    case unavailable
}

@Mockable(.macro) private protocol AsyncSampleService {
    var current: Int { get async throws(AsyncSampleFailure) }

    func fetch(_ key: String) async throws(AsyncSampleFailure) -> Int
}

@Mockable(.macro) private protocol SampleWorker: Actor {
    func work(_ value: Int) -> String
}

@MainActor
@Mockable(.macro) private protocol MainActorViewService {
    static var enabled: Bool { get }
    func title() -> String
}

@Mockable(.macro) private protocol CallbackSampleService {
    func load(_ key: Int, completion: (Int) -> Void)
    func transform<Value: Equatable>(_ value: Value, completion: (Value) -> Void)
    func combine(_ first: (Int) -> Void, second: (String) -> Void)
}

@Test private func asyncAndTypedThrowingRequirementsKeepTheirEffects() async throws {
    let returning = AsyncSampleServiceMock()

    // Configuration itself remains synchronous; effects belong to invocation.
    Given(returning).current.willReturn(8)
    Given(returning).fetch(.value("count")).willReturn(3)

    #expect(try await returning.current == 8)
    #expect(try await returning.fetch("count") == 3)
    Verify(returning, 1).current()
    Verify(returning, 1).fetch(.value("count"))

    let throwing = AsyncSampleServiceMock()
    Given(throwing).fetch(.any).willThrow(.unavailable)

    // A typed-throws protocol requirement accepts only its declared error type.
    let error = await #expect(throws: AsyncSampleFailure.self) {
        try await throwing.fetch("missing")
    }
    #expect(error == .unavailable)
}

@Test private func actorMocksConfigureOutsideTheirActor() async {
    let worker = SampleWorkerMock()

    // Generated configuration and verification builders are nonisolated. Only
    // the original actor requirement needs `await`.
    Given(worker).work(.any).willReturn("done")

    #expect(await worker.work(1) == "done")
    Verify(worker, 1).work(.value(1))
}

@Test @MainActor private func globalActorIsolationIsPreserved() {
    let view = MainActorViewServiceMock()

    Given(view).title().willReturn("Ready")
    Given(MainActorViewServiceMock.self).enabled.willReturn(true)

    #expect(view.title() == "Ready")
    #expect(MainActorViewServiceMock.enabled)
    Verify(view, 1).title()
    Verify(MainActorViewServiceMock.self, 1).enabled()
}

@Test private func nonescapingCallbacksAreForwardedSynchronously() {
    let service = CallbackSampleServiceMock()
    var loaded = 0
    var transformed = 0
    var combined = ""

    // Callback parameters are not retained or recorded. Perform receives them
    // synchronously, while ordinary arguments remain matchable and verifiable.
    Perform(service).load(.value(4)) { key, completion in
        completion(key + 1)
    }
    Perform(service).transform(.value(6)) { value, completion in
        completion(value + 1)
    }
    Perform(service).combine { first, second in
        first(3)
        second("x")
    }

    service.load(4) { loaded = $0 }
    service.transform(6) { transformed = $0 }
    service.combine {
        combined += String($0)
    } second: {
        combined += $0
    }

    #expect(loaded == 5)
    #expect(transformed == 7)
    #expect(combined == "3x")
    Verify(service, 1).load(.value(4))
    Verify(service, 1).transform(.value(6))
    Verify(service, 1).combine()
}
