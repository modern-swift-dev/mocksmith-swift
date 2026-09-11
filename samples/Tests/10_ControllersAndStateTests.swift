import Mocksmith
import MocksmithTesting
import Testing

private enum ControlledFailure: Error {
    case unavailable
}

@Mockable(.macro) private protocol ControlledService {
    var token: String? { get set }
    func load() async throws(ControlledFailure) -> String
}

@Test private func controlsStateResultsAndCallAssertions() async throws {
    let service = ControlledServiceMock()
    let token = MockState(service).token(initial: nil)
    Given(service).load()
        .willResolve(.success("ready"))
        .thenResolve(.failure(.unavailable))

    service.token = "token"
    #expect(token.value == "token")
    await Calls(service).token(set: .any).expectCount(1, timeout: .seconds(1))
    #expect(try await service.load() == "ready")
    await #expect(throws: ControlledFailure.unavailable) { try await service.load() }
}
