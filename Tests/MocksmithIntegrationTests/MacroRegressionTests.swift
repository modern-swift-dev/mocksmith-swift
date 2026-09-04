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

@Mockable private protocol OptionalCallbackRegression {
    init(callback: (() -> Void)?)
    func run(_ callback: (() -> Void)?) -> Int
    func runSendable(_ callback: (@Sendable () -> Void)?) -> Int
    func runArray(_ callbacks: [() -> Void]) -> Int
    subscript(callback: (() -> Void)?) -> Int { get }
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

@Test private func optionalAndContainerCallbacksAreRetainedArguments() {
    let mock = OptionalCallbackRegressionMock(callback: nil)
    var invocations = 0
    Given(mock).run(.any).willAnswer { callback in
        callback?()
        return callback == nil ? 0 : 1
    }
    Given(mock).runSendable(.any).willAnswer { callback in
        callback?()
        return callback == nil ? 0 : 1
    }
    Given(mock).runArray(.any).willAnswer { callbacks in
        callbacks.forEach { $0() }
        return callbacks.count
    }
    Given(mock).subscriptGet(callback: .any).willReturn(5)

    #expect(mock.run(nil) == 0)
    #expect(mock.run { invocations += 1 } == 1)
    #expect(mock.runSendable(nil) == 0)
    #expect(mock.runSendable {} == 1)
    #expect(mock.runArray([{ invocations += 1 }]) == 1)
    #expect(invocations == 2)
    #expect(mock[nil] == 5)
    Verify(mock, 2).run(.any)
}
