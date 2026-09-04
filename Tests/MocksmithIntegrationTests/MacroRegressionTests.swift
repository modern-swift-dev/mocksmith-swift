import Mocksmith
import MocksmithTesting
import Testing

@Mockable private protocol ThrowingGenericRegression {
    func run<T>(_ value: T) throws -> T
    func runAsync<T>(_ value: T) async throws -> T
}

@Mockable private protocol QualifiedAssociatedTypeRegression {
    associatedtype Element
    // Keep the qualified member spelling exercised by this regression.
    // swiftformat:disable:next opaqueGenericParameters
    func run<T: Collection>(_ values: T) -> Element where T.Element == Element
    func explicitSelf(_ value: Self.Element) -> Self.Element
    func label(Element: Element) -> Element
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

@Test private func associatedTypeRewritePreservesQualifiedMembersAndLabels() {
    let mock = QualifiedAssociatedTypeRegressionMock<Int>()
    Given(mock).run(Parameter<[Int]>.any).willReturn(2)
    Given(mock).explicitSelf(.any).willReturn(3)
    Given(mock).label(Element: .any).willReturn(4)

    #expect(mock.run([1]) == 2)
    #expect(mock.explicitSelf(1) == 3)
    #expect(mock.label(Element: 1) == 4)
}
