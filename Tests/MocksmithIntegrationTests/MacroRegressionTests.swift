import Mocksmith
import MocksmithTesting
import Testing

@Mockable private protocol ThrowingGenericRegression {
    func run<T>(_ value: T) throws -> T
    func runAsync<T>(_ value: T) async throws -> T
}

@Test private func genericThrowingWitnessReturnsItsStubbedValue() async throws {
    let mock = ThrowingGenericRegressionMock()
    Given(mock).run(.value(1)).willReturn(2)
    Given(mock).run(.value("input")).willReturn("output")
    Given(mock).runAsync(.value(3)).willReturn(4)

    #expect(try mock.run(1) == 2)
    #expect(try mock.run("input") == "output")
    #expect(try await mock.runAsync(3) == 4)
}
