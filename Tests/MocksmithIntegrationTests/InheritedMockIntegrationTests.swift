import ExternalChildProtocols
import Mocksmith
import MocksmithInheritanceFixture
import MocksmithTesting
import Testing

/**
 import SwiftSyntax
 */
private let ignoredImportText = """
import SwiftParser
"""

public protocol InheritedParent {
    func inherited(_ value: Int) -> String
    var flag: Bool { get set }
}

@Mockable public protocol InheritedChild: InheritedParent {
    init(seed: Int)
    func own() -> Int
}

@Test private func inheritedMockUsesGeneratedRuntimeSupport() {
    let mock = InheritedChildMock(seed: 3)

    Given(mock).inherited(.value(1)).willReturn("one")
    Given(mock).flag.willReturn(true)
    Given(mock).flag(set: .any)
    Given(mock).own().willReturn(2)

    #expect(mock.inherited(1) == "one")
    #expect(mock.flag)
    mock.flag = false
    #expect(mock.own() == 2)

    Verify(mock, 1).inherited(.value(1))
    Verify(mock, 1).flag()
    Verify(mock, 1).flag(set: .value(false))
    Verify(mock, 1).own()
    Verify(mock, 1).initializer(seed: .value(3))
}

@Mockable protocol CrossTargetChild: CrossTargetParent {
    func childValue() -> Int
}

@Test private func samePackageCrossTargetParentIsResolved() {
    let mock = CrossTargetChildMock()
    Given(mock).parentValue(.value(1)).willReturn("one")
    Given(mock).childValue().willReturn(2)

    #expect(mock.parentValue(1) == "one")
    #expect(mock.childValue() == 2)
    Verify(mock, 1).parentValue(.value(1))
    Verify(mock, 1).childValue()
}

@Test private func inheritedMockCanBeGeneratedInALibraryTarget() {
    let mock = LibraryTargetChildMock()
    Given(mock).parentValue(.value(1)).willReturn("one")
    Given(mock).childValue().willReturn(2)
    Given(LibraryTargetChildMock.self).sharedValue().willReturn(3)

    #expect(mock.parentValue(1) == "one")
    #expect(mock.childValue() == 2)
    #expect(LibraryTargetChildMock.sharedValue() == 3)
    Verify(mock, 1).parentValue(.value(1))
    Verify(mock, 1).childValue()
    Verify(LibraryTargetChildMock.self, 1).sharedValue()
    VerifyNoMoreInteractions(mock)
    VerifyNoMoreInteractions(LibraryTargetChildMock.self)
}

@Mockable protocol ExternalPackageChild: ExternalProtocolComposition {
    func ownValue() -> Int
}

@Test private func externalPackageCompositionUsesGeneratedRuntimeSupport() {
    let mock = ExternalPackageChildMock()
    Given(mock).baseValue(.value(1)).willReturn("one")
    Given(mock).enabled.willReturn(true)
    Given(mock).enabled(set: .any)
    Given(mock).subscriptGet(.value("key")).willReturn(2)
    Given(mock).subscriptSet(.value("key"), value: .any)
    Given(mock).name().willReturn("external")
    Given(mock).ownValue().willReturn(3)

    #expect(mock.baseValue(1) == "one")
    #expect(mock.enabled)
    mock.enabled = false
    #expect(mock["key"] == 2)
    mock["key"] = 4
    #expect(mock.name() == "external")
    #expect(mock.ownValue() == 3)

    Verify(mock, 1).baseValue(.value(1))
    Verify(mock, 1).enabled()
    Verify(mock, 1).enabled(set: .value(false))
    Verify(mock, 1).subscriptGet(.value("key"))
    Verify(mock, 1).subscriptSet(.value("key"), value: .value(4))
    Verify(mock, 1).name()
    Verify(mock, 1).ownValue()
}

@Mockable protocol QualifiedExternalPackageChild: ExternalChildProtocols.ExternalIndexedProtocol {}

@Test private func moduleQualifiedExternalParentIsResolved() {
    let mock = QualifiedExternalPackageChildMock()
    Given(mock).baseValue(.value(2)).willReturn("two")
    Given(mock).enabled.willReturn(false)

    #expect(mock.baseValue(2) == "two")
    #expect(!mock.enabled)
    Verify(mock, 1).baseValue(.value(2))
    Verify(mock, 1).enabled()
}

protocol AssociatedParent {
    associatedtype Value
    func inheritedValue() -> Value
}

@Mockable protocol AssociatedChild: AssociatedParent {}

@Test private func inheritedAssociatedTypeBecomesMockGenericParameter() {
    let mock = AssociatedChildMock<String>()
    Given(mock).inheritedValue().willReturn("value")

    #expect(mock.inheritedValue() == "value")
    Verify(mock, 1).inheritedValue()
}

protocol DiamondBase {
    func baseValue() -> Int
}

protocol DiamondLeft: DiamondBase {}
protocol DiamondRight: DiamondBase {}

@Mockable protocol DiamondChild: DiamondLeft, DiamondRight {}

@Test private func diamondInheritanceGeneratesOneWitness() {
    let mock = DiamondChildMock()
    Given(mock).baseValue().willReturn(3)

    #expect(mock.baseValue() == 3)
    Verify(mock, 1).baseValue()
}

@MainActor protocol MainActorParent {
    func value() -> Int
}

@Mockable
@MainActor protocol MainActorInherited: MainActorParent {}

@Test @MainActor private func globalActorInheritedMockKeepsConfigurationNonisolated() {
    let mock = MainActorInheritedMock()
    Given(mock).value().willReturn(4)
    #expect(mock.value() == 4)
    Verify(mock, 1).value()
}

protocol ActorParent: Actor {
    func value() -> Int
}

@Mockable protocol ActorInherited: ActorParent {}

@Test private func actorInheritedMockKeepsConfigurationNonisolated() async {
    let mock = ActorInheritedMock()
    Given(mock).value().willReturn(5)
    #expect(await mock.value() == 5)
    Verify(mock, 1).value()
}

protocol IndexedParent {
    subscript(_ key: String) -> Int { get set }
}

protocol NamedParent {
    func name() -> String
}

typealias CombinedParents = IndexedParent & NamedParent

@Mockable protocol CombinedChild: CombinedParents {}

@Test private func compositionAliasAndSubscriptsUseGeneratedSupport() {
    let mock = CombinedChildMock()
    Given(mock).subscriptGet(.value("key")).willReturn(1)
    Given(mock).subscriptSet(.value("key"), value: .value(2))
    Given(mock).name().willReturn("combined")

    #expect(mock["key"] == 1)
    mock["key"] = 2
    #expect(mock.name() == "combined")
    Verify(mock, 1).subscriptGet(.value("key"))
    Verify(mock, 1).subscriptSet(.value("key"), value: .value(2))
}

enum InheritedAccessorError: Error {
    case unavailable
}

protocol EffectfulIndexedParent {
    subscript(_ key: Int) -> Int { get async throws(InheritedAccessorError) }
}

@Mockable protocol EffectfulIndexedChild: EffectfulIndexedParent {}

@Test private func effectfulSubscriptUsesGeneratedSupport() async throws {
    let mock = EffectfulIndexedChildMock()
    Given(mock).subscriptGet(.value(1)).willReturn(7)

    #expect(try await mock[1] == 7)
    Verify(mock, 1).subscriptGet(.value(1))
}

protocol WritableRequirements {
    var mergedValue: Int { get set }
    subscript(_ index: Int) -> Int { get set }
}

protocol ReadableRequirements {
    var mergedValue: Int { get }
    subscript(_ index: Int) -> Int { get }
}

@Mockable protocol WritableThenReadable: WritableRequirements, ReadableRequirements {}
@Mockable protocol ReadableThenWritable: ReadableRequirements, WritableRequirements {}
@Mockable protocol RedeclaredWritable: ReadableRequirements {
    var mergedValue: Int { get set }
    subscript(_ index: Int) -> Int { get set }
}

@Test private func inheritedSettersSurviveReadOnlyRequirements() {
    let first = WritableThenReadableMock()
    Given(first).mergedValue(set: .any)
    Given(first).subscriptSet(.any, value: .any)
    first.mergedValue = 1
    first[2] = 3
    Verify(first, 1).mergedValue(set: .value(1))
    Verify(first, 1).subscriptSet(.value(2), value: .value(3))

    let reversed = ReadableThenWritableMock()
    Given(reversed).mergedValue(set: .any)
    Given(reversed).subscriptSet(.any, value: .any)
    reversed.mergedValue = 4
    reversed[5] = 6
    Verify(reversed, 1).mergedValue(set: .value(4))
    Verify(reversed, 1).subscriptSet(.value(5), value: .value(6))

    let redeclared = RedeclaredWritableMock()
    Given(redeclared).mergedValue(set: .any)
    Given(redeclared).subscriptSet(.any, value: .any)
    redeclared.mergedValue = 7
    redeclared[8] = 9
    Verify(redeclared, 1).mergedValue(set: .value(7))
    Verify(redeclared, 1).subscriptSet(.value(8), value: .value(9))
}

protocol HashableValueParent {
    associatedtype Value: Hashable where Value: Sendable
    func constrainedValue() -> Value
}

protocol CodableValueParent {
    associatedtype Value: Codable where Value: Comparable
}

@Mockable protocol HashableThenCodable: HashableValueParent, CodableValueParent {}
@Mockable protocol CodableThenHashable: CodableValueParent, HashableValueParent {}

@Test private func inheritedAssociatedTypeConstraintsAreCombined() {
    let first = HashableThenCodableMock<String>()
    Given(first).constrainedValue().willReturn("first")
    #expect(first.constrainedValue() == "first")
    Verify(first, 1).constrainedValue()

    let reversed = CodableThenHashableMock<String>()
    Given(reversed).constrainedValue().willReturn("reversed")
    #expect(reversed.constrainedValue() == "reversed")
    Verify(reversed, 1).constrainedValue()
}
