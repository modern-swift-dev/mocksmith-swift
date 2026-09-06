import Mocksmith
import MocksmithTesting
import Testing

#if canImport(ObjectiveC)
    import Foundation
#endif

@Mockable private protocol GenericRepositorySample {
    associatedtype Item: Equatable

    func load() -> Item
    func echo<Value: Equatable>(_ value: Value) -> Value
}

@Mockable private protocol RethrowsSampleService {
    func run<Value>(_ body: () throws -> Value) rethrows -> Value
}

@Mockable private protocol SelfSampleService: AnyObject {
    static func make() -> Self
    func clone() -> Self
    func isSame(as other: Self) -> Bool
}

@Mockable private protocol OwnershipSampleService {
    func borrow(_ value: borrowing String) -> Int
    func consume(_ value: consuming String) -> Int
    func send(_ value: sending String) -> Int
}

private protocol SampleIdentifiedValue {
    var id: Int { get }
}

private struct SampleIdentifier: SampleIdentifiedValue, Equatable {
    let id: Int
}

@Mockable private protocol PackAndOpaqueSampleService {
    init<each Seed>(_ seed: repeat each Seed)
    func describe<each Element>(_ values: repeat each Element) -> Int
    func identifier(_ value: some SampleIdentifiedValue) -> Int
    subscript<each Element>(_ values: repeat each Element) -> Int { get }
}

#if canImport(ObjectiveC)
    @objc
    @Mockable private protocol ObjectiveCSampleService: NSObjectProtocol {
        @objc(fetchValue:) optional func fetch(_ value: Int) -> String?

        @objc optional var title: String? { get }
    }
#endif

@Test private func associatedAndGenericTypesRemainCompileTimeChecked() {
    // Associated types become generated mock generic parameters.
    let repository = GenericRepositorySampleMock<String>()
    Given(repository).load().willReturn("loaded")

    // Each generic method specialization has isolated stubs and invocations.
    Given(repository).echo(.value("input")).willReturn("output")
    Given(repository).echo(.value(1)).willReturn(2)

    #expect(repository.load() == "loaded")
    #expect(repository.echo("input") == "output")
    #expect(repository.echo(1) == 2)
    Verify(repository, 1).echo(.value("input"))
    Verify(repository, 1).echo(.value(1))
}

@Test private func rethrowsCallbacksStayNonescapingAndSpecialized() {
    let service = RethrowsSampleServiceMock()
    var callbackResult = 0

    Given(service).run().willReturn(42)
    Perform(service).run { (callback: () throws -> Int) in
        // Perform actions are nonthrowing, so the action decides how to handle
        // an error from the forwarded callback.
        callbackResult = (try? callback()) ?? -1
    }

    #expect(service.run { 7 } == 42)
    #expect(callbackResult == 7)

    // Return-only generic requirements use a metatype token during Verify.
    Verify(service, 1).run(returning: Int.self)
}

@Test private func selfRequirementsUseTheConcreteGeneratedMockType() {
    let service = SelfSampleServiceMock()

    Given(service).clone().willReturn(service)
    Given(service).isSame(as: .sameInstance(service)).willReturn(true)
    Given(SelfSampleServiceMock.self).make().willReturn(service)

    #expect(service.clone() === service)
    #expect(service.isSame(as: service))
    #expect(SelfSampleServiceMock.make() === service)
    Verify(service, 1).isSame(as: .sameInstance(service))
}

@Test private func copyableOwnershipModifiersRecordSnapshots() {
    let service = OwnershipSampleServiceMock()

    // Copyable borrowing, consuming, and sending parameters can all be matched
    // and verified because the generated channel records a safe snapshot.
    Given(service).borrow(.value("borrowed")).willReturn(1)
    Given(service).consume(.value("consumed")).willReturn(2)
    Given(service).send(.value("sent")).willReturn(3)

    #expect(service.borrow("borrowed") == 1)
    #expect(service.consume("consumed") == 2)
    #expect(service.send("sent") == 3)
    Verify(service, 1).borrow(.value("borrowed"))
    Verify(service, 1).consume(.value("consumed"))
    Verify(service, 1).send(.value("sent"))
}

@Test private func parameterPacksAndOpaqueInputsGetTypedFactories() {
    let service = PackAndOpaqueSampleServiceMock(0, "seed")
    let identifier = SampleIdentifier(id: 7)

    // Pack elements become individual matcher arguments in generated selectors.
    Given(service).describe(.value(1), .value("a")).willReturn(2)
    Given(service).subscriptGet(.value(1), .value("a")).willReturn(3)

    // A concrete value satisfying `some Protocol` remains type-safe.
    Given(service).identifier(.value(identifier)).willReturn(7)

    #expect(service.describe(1, "a") == 2)
    #expect(service[1, "a"] == 3)
    #expect(service.identifier(identifier) == 7)
    Verify(service, 1).initializer(.value(0), .value("seed"))
    Verify(service, 1).describe(.value(1), .value("a"))
    Verify(service, 1).subscriptGet(.value(1), .value("a"))
    Verify(service, 1).identifier(.value(identifier))
}

#if canImport(ObjectiveC)
    @Test private func objectiveCOptionalRequirementsUseTheSameDSL() {
        let service = ObjectiveCSampleServiceMock()

        // On Apple platforms the generated mock subclasses NSObject and implements
        // optional Objective-C methods and properties with their original selectors.
        Given(service).fetch(.value(1)).willReturn("one")
        Given(service).title.willReturn("sample")

        #expect(service.fetch(1) == "one")
        #expect(service.title == "sample")
        Verify(service, 1).fetch(.value(1))
        Verify(service, 1).title()
    }
#endif
