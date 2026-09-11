import Mocksmith
import MocksmithTesting
import Testing

@Mockable(.macro) private protocol AdvancedMembersService {
    init(seed: Int)

    static var sharedValue: Int { get set }
    static func make(_ value: Int) -> String

    subscript(_ key: String) -> Int { get set }
}

@Mockable(.macro) private protocol RepositoryService {
    associatedtype Item: Equatable

    func load() -> Item
    func convert(_ value: Int) -> String
    func convert(_ value: String) -> Int
    func total(_ values: Int...) -> Int
    func mutate(_ value: inout Int)
}

@Test private func staticMembersSubscriptsAndInitializersUseTypedFactories() {
    // Required initializers are the only members that do not need a stub. They
    // construct the mock and record their arguments for later verification.
    let service = AdvancedMembersServiceMock(seed: 1)

    // Pass a mock metatype to configure and verify static requirements.
    Given(AdvancedMembersServiceMock.self).make(.value(2)).willReturn("two")
    Given(AdvancedMembersServiceMock.self).sharedValue.willReturn(10)
    Given(AdvancedMembersServiceMock.self).sharedValue(set: .any)

    // Generated names distinguish reads and writes. Setter selectors include
    // both index arguments and the new value.
    Given(service).subscriptGet(.value("answer")).willReturn(42)
    Given(service).subscriptSet(.value("answer"), value: .value(43))

    #expect(AdvancedMembersServiceMock.make(2) == "two")
    #expect(AdvancedMembersServiceMock.sharedValue == 10)
    AdvancedMembersServiceMock.sharedValue = 11
    #expect(service["answer"] == 42)
    service["answer"] = 43

    Verify(AdvancedMembersServiceMock.self, 1).make(.value(2))
    Verify(AdvancedMembersServiceMock.self, 1).sharedValue()
    Verify(AdvancedMembersServiceMock.self, 1).sharedValue(set: .value(11))
    Verify(service, 1).subscriptGet(.value("answer"))
    Verify(service, 1).subscriptSet(.value("answer"), value: .value(43))
    Verify(service, 1).initializer(seed: .value(1))
}

@Test private func associatedTypesOverloadsVariadicsAndInoutStayTyped() {
    // Associated types become generic arguments on the generated mock.
    let repository = RepositoryServiceMock<String>()
    var mutableValue = 5

    Given(repository).load().willReturn("loaded")

    // Overloads produce overloads in the generated DSL; Swift selects each one
    // from matcher and return types.
    Given(repository).convert(.value(1)).willReturn("one")
    Given(repository).convert(.value("two")).willReturn(2)

    // Variadic arguments are captured as one array. `inout` records the value
    // present when the method is entered.
    Given(repository).total(.value([1, 2, 3])).willReturn(6)
    Given(repository).mutate(.value(5))

    #expect(repository.load() == "loaded")
    #expect(repository.convert(1) == "one")
    #expect(repository.convert("two") == 2)
    #expect(repository.total(1, 2, 3) == 6)
    repository.mutate(&mutableValue)

    Verify(repository, 1).load()
    Verify(repository, 1).convert(.value(1))
    Verify(repository, 1).convert(.value("two"))
    Verify(repository, 1).total(.value([1, 2, 3]))
    Verify(repository, 1).mutate(.value(5))
}
