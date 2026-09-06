import Mocksmith
import MocksmithTesting
import Testing

#if canImport(ObjectiveC)
    import Foundation
#endif

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}

@Mockable private protocol WeatherService {
    var unit: String { get set }

    func temperature(for city: String) async throws -> Double
    func save(_ value: Int)
    func greeting() -> String
    func status() async -> String
    func format(_ value: Int, prefix: String) -> String
}

@Mockable private protocol AdvancedService {
    init(seed: Int)

    static var sharedValue: Int { get set }
    static func make(_ value: Int) -> String
    static func version() -> String

    subscript(_ key: String) -> Int { get set }
}

@Mockable private protocol StatefulStaticService {
    static var value: Int { get set }
}

@Mockable private protocol OrderedService {
    init(seed: Int)
    static func make(_ value: Int) -> String
    func save(_ value: Int)
}

@Mockable private protocol Repository {
    associatedtype Item: Equatable

    func load() -> Item
    func convert(_ value: Int) -> String
    func convert(_ value: String) -> Int
    func total(_ values: Int...) -> Int
    func mutate(_ value: inout Int)
}

@Mockable private protocol Worker: Actor {
    func work(_ value: Int) -> String
}

private enum LoadFailure: Error, Equatable {
    case unavailable
}

@Mockable private protocol TypedThrower {
    func load(_ key: String) throws(LoadFailure) -> Int
    func refresh() throws(LoadFailure)
    func refreshAsync() async throws(LoadFailure)
    var label: String { get throws(LoadFailure) }
    var message: String { get throws }
}

@Mockable private protocol GenericService {
    func echo<Value: Equatable>(_ value: Value) -> Value
    func run<Value>(_ body: () throws -> Value) rethrows -> Value
}

@Mockable private protocol AssociatedOnly<Element> {
    associatedtype Element: Sendable where Element: Equatable
}

@Mockable private protocol StaticGenericService {
    static func identity<Value: Equatable>(_ value: Value) -> Value
}

@MainActor
@Mockable private protocol MainActorService {
    static var enabled: Bool { get }
    func title() -> String
}

@MainActor
@Mockable private protocol StatefulMainActorService {
    static var enabled: Bool { get }
}

@Mockable private protocol SelfService: AnyObject {
    static func make() -> Self
    func clone() -> Self
    func isSame(as other: Self) -> Bool
}

@Mockable private protocol OwnershipService {
    func borrow(_ value: borrowing String) -> Int
    func consume(_ value: consuming String) -> Int
    func send(_ value: sending String) -> Int
}

@Mockable private protocol ProtocolWhereService<Element> where Element: Equatable {
    associatedtype Element
    mutating func update() -> Int
}

private struct NoncopyableToken: ~Copyable {
    let raw: Int
}

@Mockable private protocol NoncopyableService: ~Copyable {
    @MockNoncopyable var token: NoncopyableToken { get set }

    @MockNoncopyable subscript(_ key: Int) -> NoncopyableToken { get set }

    @MockNoncopyable func inspect(_ token: borrowing NoncopyableToken) -> Int

    @MockNoncopyable func consume(_ prefix: Int, token: consuming NoncopyableToken) -> Int

    @MockNoncopyable func make() -> NoncopyableToken
    @MockNoncopyable func makeThrowing() throws(LoadFailure) -> NoncopyableToken
}

@Mockable private protocol NoncopyableInitializerService: ~Copyable {
    @MockNoncopyable init(_ token: consuming NoncopyableToken)
}

@Mockable private protocol GenericNoncopyableInitializerService: ~Copyable {
    @MockNoncopyable init(_ value: consuming some ~Copyable)
}

@Mockable private protocol EffectfulAccessorService {
    var current: Int { get async throws(LoadFailure) }
    static subscript(_ key: Int) -> String { get }
    subscript(_ key: some Hashable) -> String { get async throws }
}

@Mockable private protocol DefaultPolicyService {
    var value: Int { get set }
    var optionalValue: Int? { get }
    var swiftOptionalValue: String? { get }
    func save(_ value: Int)
    func optionalResult() -> Int?
    func optionalClosure() -> (() -> Void)?
    func asyncSave() async
    func asyncOptional() async -> Int?
    @MainActor func mainActorAsyncSave() async
    @MainActor func mainActorAsyncOptional() async -> Int?
    @MainActor var mainActorAsyncOptionalValue: Int? { get async }
    @MainActor subscript(_ key: Bool) -> Int? { get async }
    func throwingVoid() throws
    static func staticSave()
    subscript(_ key: String) -> Int { get set }
}

private protocol IdentifiedValue {
    var id: Int { get }
}

private struct Identifier: IdentifiedValue, Equatable {
    let id: Int
}

@Mockable private protocol PackAndOpaqueService {
    init<each Seed>(_ seed: repeat each Seed)
    func describe<each Element>(_ values: repeat each Element) -> Int
    func identifier(_ value: some IdentifiedValue) -> Int
    subscript<each Element>(_ values: repeat each Element) -> Int { get }
}

@Mockable private protocol CallbackService {
    func load(_ key: Int, completion: (Int) -> Void)
    func transform<Value: Equatable>(_ value: Value, completion: (Value) -> Void)
    static func load(_ key: String, completion: (String) -> Void)
    func combine(_ first: (Int) -> Void, second: (String) -> Void)
    func resolve(_ key: Int, compute: () -> Int) -> Int
}

@Mockable private protocol EscapingCallbackService {
    func fetch(completion: @escaping @MainActor @Sendable (Result<[String], Error>) -> Void)
}

#if canImport(ObjectiveC)
    @objc
    @Mockable private protocol ObjectiveCService: NSObjectProtocol {
        @objc(fetchValue:) optional func fetch(_ value: Int) -> String?

        @objc optional var title: String? { get }
    }
#endif

@Test private func generatedPropertyStateControlsValuesSettersAndPrecedence() {
    let mock = WeatherServiceMock()
    let unit = MockState(mock).unit(initial: "metric")

    #expect(mock.unit == "metric")
    unit.value = "custom"
    #expect(mock.unit == "custom")
    mock.unit = "imperial"
    #expect(unit.value == "imperial")
    #expect(Calls(mock).unit(set: .any).arguments == ["imperial"])

    resetMock(mock, scopes: [.invocations])
    #expect(unit.value == "imperial")
    #expect(Calls(mock).unit(set: .any).count == 0)

    Given(mock).unit.willReturn("stubbed")
    #expect(mock.unit == "stubbed")
    let replacement = MockState(mock).unit(initial: "replacement")
    #expect(mock.unit == "replacement")
    #expect(replacement.value == "replacement")
}

@Test private func generatedPropertyStateSupportsTypedAndAsyncThrowingGetters() async throws {
    let thrower = TypedThrowerMock()
    let label = MockState(thrower).label(initial: .failure(.unavailable))
    #expect(throws: LoadFailure.unavailable) { try thrower.label }
    label.succeed(with: "ready")
    #expect(try thrower.label == "ready")

    let message = MockState(thrower).message(
        initial: Result<String, any Error>.failure(LoadFailure.unavailable)
    )
    #expect(throws: LoadFailure.unavailable) { try thrower.message }
    message.succeed(with: "available")
    #expect(try thrower.message == "available")

    let accessors = EffectfulAccessorServiceMock()
    let current = MockState(accessors).current(initial: .success(7))
    #expect(try await accessors.current == 7)
    current.fail(with: .unavailable)
    await #expect(throws: LoadFailure.unavailable) { try await accessors.current }
}

@Test private func generatedPropertyStateSupportsStaticProperties() {
    resetMock(StatefulStaticServiceMock.self)
    let shared = MockState(StatefulStaticServiceMock.self).value(initial: 10)

    #expect(StatefulStaticServiceMock.value == 10)
    StatefulStaticServiceMock.value = 11
    #expect(shared.value == 11)
    shared.value = 12
    #expect(StatefulStaticServiceMock.value == 12)

    resetMock(StatefulStaticServiceMock.self)
}

@Test @MainActor private func generatedPropertyStatePreservesGlobalActorIsolation() {
    let enabled = MockState(StatefulMainActorServiceMock.self).enabled(initial: false)
    #expect(!StatefulMainActorServiceMock.enabled)
    enabled.value = true
    #expect(StatefulMainActorServiceMock.enabled)
}

@Test private func generatedMockSupportsMethodsPropertiesAndTypedDSL() async throws {
    let mock = WeatherServiceMock()
    let cities = ArgumentCaptor<String>()
    var performedCities: [String] = []

    Given(mock).temperature(for: .value("Toronto")).willReturn(20, 21)
    Given(mock).save(.any)
    Given(mock).greeting().willReturn("hello")
    Given(mock).unit.willReturn("C")
    Given(mock).unit(set: .any)
    Perform(mock).temperature(for: .any) { performedCities.append($0) }

    #expect(try await mock.temperature(for: "Toronto") == 20)
    #expect(try await mock.temperature(for: "Toronto") == 21)
    #expect(try await mock.temperature(for: "Toronto") == 21)
    mock.save(7)
    #expect(mock.greeting() == "hello")
    #expect(mock.unit == "C")
    mock.unit = "F"

    let temperatureCalls = Calls(mock).temperature(for: .value("Toronto"))
    #expect(temperatureCalls.count == 3)
    #expect(temperatureCalls.arguments == ["Toronto", "Toronto", "Toronto"])
    #expect(Calls(mock).greeting().count == 1)
    #expect(Calls(mock).unit().count == 1)
    #expect(Calls(mock).unit(set: .value("F")).count == 1)

    Verify(mock, 3).temperature(for: .capturing(cities))
    Verify(mock, 1).save(.value(7))
    Verify(mock, 1).greeting()
    Verify(mock, 1).unit()
    Verify(mock, 1).unit(set: .value("F"))
    VerifyNoMoreInteractions(mock)
    #expect(cities.values == ["Toronto", "Toronto", "Toronto"])
    #expect(performedCities == ["Toronto", "Toronto", "Toronto"])
}

@Test private func generatedConfigurationInitializersRunAfterInitializerRecording() {
    let mock = WeatherServiceMock { configured in
        Given(configured).greeting().willReturn("configured")
    }
    #expect(mock.greeting() == "configured")

    let required = AdvancedServiceMock(seed: 12) { configured in
        Given(configured).subscriptGet(.value("answer")).willReturn(42)
    }
    #expect(required["answer"] == 42)
    Verify(required, 1).initializer(seed: .value(12))
}

@Test private func generatedCallsCanWaitWithoutVerifying() async throws {
    let mock = WeatherServiceMock()
    Given(mock).temperature(for: .any).willReturn(20)
    let calls = Calls(mock).temperature(for: .value("Toronto"))
    let waiting = Task {
        try await calls.waitForCount(1, timeout: .seconds(1))
    }

    await Task.yield()
    _ = try await mock.temperature(for: "Toronto")
    try await waiting.value
    #expect(calls.arguments == ["Toronto"])

    Verify(mock, 1).temperature(for: .value("Toronto"))
    VerifyNoMoreInteractions(mock)
}

@Test private func generatedAsyncMembersSupportDeferredFIFOOutcomes() async throws {
    let weather = WeatherServiceMock()
    let weatherBox = UncheckedSendableBox(weather)
    let temperatures = Given(weather).temperature(for: .any).willSuspend()
    let toronto = Task { try await weatherBox.value.temperature(for: "Toronto") }
    try await temperatures.waitUntilCalled(timeout: .seconds(1))
    let montreal = Task { try await weatherBox.value.temperature(for: "Montreal") }
    try await temperatures.waitUntilCalled(count: 2, timeout: .seconds(1))
    #expect(temperatures.arguments == ["Toronto", "Montreal"])
    temperatures.resume(returning: 20)
    temperatures.resume(returning: 21)
    #expect(try await toronto.value == 20)
    #expect(try await montreal.value == 21)

    let cancelled = Given(weather).temperature(for: .value("cancelled"))
        .willSuspend(cancellation: .fail(with: CancellationError()))
    let cancelledTask = Task { try await weatherBox.value.temperature(for: "cancelled") }
    try await cancelled.waitUntilCalled(timeout: .seconds(1))
    cancelledTask.cancel()
    await #expect(throws: CancellationError.self) { try await cancelledTask.value }

    let status = Given(weather).status().willSuspend().thenReturn("ready")
    let waitingStatus = Task { await weatherBox.value.status() }
    try await status.waitUntilCalled(timeout: .seconds(1))
    status.resume(returning: "starting")
    #expect(await waitingStatus.value == "starting")
    #expect(await weather.status() == "ready")

    let accessors = EffectfulAccessorServiceMock()
    let accessorsBox = UncheckedSendableBox(accessors)
    let current = Given(accessors).current.willSuspend(cancellation: .fail(with: .unavailable))
    let waitingCurrent = Task { try await accessorsBox.value.current }
    try await current.waitUntilCalled(timeout: .seconds(1))
    current.resume(throwing: .unavailable)
    await #expect(throws: LoadFailure.unavailable) { try await waitingCurrent.value }

    let subscriptValue = Given(accessors).subscriptGet(.value("key")).willSuspend()
    let waitingSubscript = Task { try await accessorsBox.value["key"] }
    try await subscriptValue.waitUntilCalled(timeout: .seconds(1))
    subscriptValue.resume(returning: "value")
    #expect(try await waitingSubscript.value == "value")
}

@Test private func generatedMockSupportsStaticMembersSubscriptsAndInitializers() {
    let mock = AdvancedServiceMock(seed: 1)

    Given(AdvancedServiceMock.self).make(.value(2)).willReturn("two")
    Given(AdvancedServiceMock.self).sharedValue.willReturn(10)
    Given(AdvancedServiceMock.self).sharedValue(set: .any)
    Given(mock).subscriptGet(.value("answer")).willReturn(42)
    Given(mock).subscriptSet(.value("answer"), value: .value(43))

    #expect(AdvancedServiceMock.make(2) == "two")
    #expect(AdvancedServiceMock.sharedValue == 10)
    AdvancedServiceMock.sharedValue = 11
    #expect(mock["answer"] == 42)
    mock["answer"] = 43

    #expect(Calls(AdvancedServiceMock.self).make(.value(2)).arguments == [2])
    #expect(Calls(AdvancedServiceMock.self).sharedValue().count == 1)
    #expect(Calls(mock).subscriptGet(.value("answer")).arguments == ["answer"])
    #expect(Calls(mock).subscriptSet(.value("answer"), value: .value(43)).count == 1)
    #expect(Calls(mock).initializer(seed: .value(1)).arguments == [1])

    Verify(AdvancedServiceMock.self, 1).make(.value(2))
    Verify(AdvancedServiceMock.self, 1).sharedValue()
    Verify(AdvancedServiceMock.self, 1).sharedValue(set: .value(11))
    Verify(mock, 1).subscriptGet(.value("answer"))
    Verify(mock, 1).subscriptSet(.value("answer"), value: .value(43))
    Verify(mock, 1).initializer(seed: .value(1))
    VerifyNoMoreInteractions(mock)
    VerifyNoMoreInteractions(AdvancedServiceMock.self)
}

@Test private func generatedMockSupportsAssociatedTypesOverloadsVariadicsAndInout() {
    let mock = RepositoryMock<String>()
    var value = 5

    Given(mock).load().willReturn("loaded")
    Given(mock).convert(.value(1)).willReturn("one")
    Given(mock).convert(.value("two")).willReturn(2)
    Given(mock).total(.value([1, 2, 3])).willReturn(6)
    Given(mock).mutate(.value(5))

    #expect(mock.load() == "loaded")
    #expect(mock.convert(1) == "one")
    #expect(mock.convert("two") == 2)
    #expect(mock.total(1, 2, 3) == 6)
    mock.mutate(&value)

    Verify(mock, 1).load()
    Verify(mock, 1).convert(.value(1))
    Verify(mock, 1).convert(.value("two"))
    Verify(mock, 1).total(.value([1, 2, 3]))
    Verify(mock, 1).mutate(.value(5))
    VerifyNoMoreInteractions(mock)
}

@Test private func generatedActorMockSupportsNonisolatedConfiguration() async {
    let mock = WorkerMock()
    Given(mock).work(.any).willReturn("done")

    #expect(await mock.work(1) == "done")
    Verify(mock, 1).work(.value(1))
}

@Test private func generatedMockSupportsTypedThrows() throws {
    let returning = TypedThrowerMock()
    Given(returning).load(.value("count")).willReturn(3)
    Given(returning).refresh()
    #expect(try returning.load("count") == 3)
    try returning.refresh()

    let throwing = TypedThrowerMock()
    Given(throwing).load(.any).willThrow(.unavailable)
    Given(throwing).refresh().willThrow(.unavailable)
    let error = #expect(throws: LoadFailure.self) { try throwing.load("missing") }
    #expect(error == .unavailable)
    #expect(throws: LoadFailure.unavailable) { try throwing.refresh() }

    Verify(returning, 1).load(.value("count"))
    Verify(returning, 1).refresh()
    Verify(throwing, 1).load(.value("missing"))
    Verify(throwing, 1).refresh()
}

@Test private func generatedThrowingBuildersChainMixedOutcomes() async throws {
    let values = TypedThrowerMock()
    Given(values).load(.any)
        .willReturn(1)
        .thenThrow(.unavailable)
        .thenReturn(3)

    #expect(try values.load("first") == 1)
    #expect(throws: LoadFailure.unavailable) { try values.load("second") }
    #expect(try values.load("third") == 3)
    #expect(try values.load("fourth") == 3)

    let void = TypedThrowerMock()
    Given(void).refresh()
        .willSucceed()
        .thenThrow(.unavailable)
        .thenSucceed()

    try void.refresh()
    #expect(throws: LoadFailure.unavailable) { try void.refresh() }
    try void.refresh()

    let transient = NoncopyableServiceMock()
    Given(transient).makeThrowing()
        .willProduce { NoncopyableToken(raw: 1) }
        .thenThrow(.unavailable)
        .thenProduce { NoncopyableToken(raw: 3) }

    #expect(try transient.makeThrowing().raw == 1)
    #expect(throws: LoadFailure.unavailable) { _ = try transient.makeThrowing() }
    #expect(try transient.makeThrowing().raw == 3)

    let accessors = EffectfulAccessorServiceMock()
    Given(accessors).current
        .willReturn(1)
        .thenThrow(.unavailable)
        .thenReturn(3)
    Given(accessors).subscriptGet(.value("key"))
        .willReturn("first")
        .thenThrow(LoadFailure.unavailable)
        .thenReturn("third")

    #expect(try await accessors.current == 1)
    await #expect(throws: LoadFailure.unavailable) { try await accessors.current }
    #expect(try await accessors.current == 3)
    #expect(try await accessors["key"] == "first")
    await #expect(throws: LoadFailure.unavailable) { try await accessors["key"] }
    #expect(try await accessors["key"] == "third")
}

@Test private func generatedAnswersUseInvocationArgumentsAndMixOutcomes() async throws {
    let weather = WeatherServiceMock()
    Given(weather).greeting()
        .willAnswer { "hello" }
        .thenAnswer { "again" }
    Given(weather).status()
        .willAnswer {
            await Task.yield()
            return "ready"
        }
        .thenAnswer { "steady" }
    Given(weather).unit
        .willAnswer { "C" }
        .thenAnswer { "F" }
    #expect(weather.greeting() == "hello")
    #expect(weather.greeting() == "again")
    #expect(await weather.status() == "ready")
    #expect(await weather.status() == "steady")
    #expect(weather.unit == "C")
    #expect(weather.unit == "F")

    Given(weather).format(.any, prefix: .any)
        .willAnswer { value, prefix in "\(prefix)\(value)" }
        .thenReturn("fixed")
        .thenAnswer { value, prefix in "\(value)\(prefix)" }
    #expect(weather.format(2, prefix: "v") == "v2")
    #expect(weather.format(3, prefix: "v") == "fixed")
    #expect(weather.format(4, prefix: "v") == "4v")
    #expect(weather.format(5, prefix: "v") == "5v")

    Given(weather).temperature(for: .any)
        .willAnswer { city in
            await Task.yield()
            return Double(city.count)
        }
        .thenReturn(99)
    #expect(try await weather.temperature(for: "Rome") == 4)
    #expect(try await weather.temperature(for: "Paris") == 99)

    let throwing = TypedThrowerMock()
    Given(throwing).load(.any).willAnswer { key in
        guard key != "missing" else {
            throw LoadFailure.unavailable
        }
        return key.count
    }
    #expect(try throwing.load("value") == 5)
    #expect(throws: LoadFailure.unavailable) { try throwing.load("missing") }

    Given(throwing).refresh()
        .willAnswer {}
        .thenThrow(.unavailable)
        .thenAnswer {}
    try throwing.refresh()
    #expect(throws: LoadFailure.unavailable) { try throwing.refresh() }
    try throwing.refresh()

    Given(throwing).refreshAsync()
        .willAnswer {}
        .thenThrow(.unavailable)
        .thenAnswer {}
    try await throwing.refreshAsync()
    await #expect(throws: LoadFailure.unavailable) { try await throwing.refreshAsync() }
    try await throwing.refreshAsync()

    Given(throwing).label
        .willAnswer { "available" }
        .thenAnswer { throw LoadFailure.unavailable }
    #expect(try throwing.label == "available")
    #expect(throws: LoadFailure.unavailable) { try throwing.label }

    let advanced = AdvancedServiceMock(seed: 0)
    Given(advanced).subscriptGet(.any).willAnswer { $0.count }
    #expect(advanced["answer"] == 6)

    Given(StaticGenericServiceMock.self).identity(Parameter<String>.any).willAnswer { $0 }
    #expect(StaticGenericServiceMock.identity("typed") == "typed")

    Given(AdvancedServiceMock.self).version()
        .willAnswer { "1" }
        .thenAnswer { "2" }
    #expect(AdvancedServiceMock.version() == "1")
    #expect(AdvancedServiceMock.version() == "2")

    let transient = NoncopyableServiceMock()
    Given(transient).inspect(.any).willAnswer { $0.raw * 2 }
    #expect(transient.inspect(NoncopyableToken(raw: 3)) == 6)
    Given(transient).make().willAnswer { NoncopyableToken(raw: 4) }
    #expect(transient.make().raw == 4)

    let callbacks = CallbackServiceMock()
    Given(callbacks).resolve(.any).willAnswer { key, compute in key + compute() }
    #expect(callbacks.resolve(4) { 5 } == 9)
}

@Test private func generatedInOrderDSLVerifiesStrictCrossMockSequence() {
    let weather = WeatherServiceMock()
    let ordered = OrderedServiceMock(seed: 7)

    Given(weather).save(.any)
    Given(ordered).save(.any)
    Given(OrderedServiceMock.self).make(.any).willReturn("made")

    weather.save(1)
    ordered.save(2)
    _ = OrderedServiceMock.make(3)

    VerifyInOrder { order in
        order.expect(ordered).initializer(seed: .value(7))
        order.expect(weather).save(.value(1))
        order.expect(ordered).save(.value(2))
        order.expect(OrderedServiceMock.self).make(.value(3))
    }
    VerifyNoMoreInteractions(weather)
    VerifyNoMoreInteractions(ordered)
    VerifyNoMoreInteractions(OrderedServiceMock.self)

    resetMock(OrderedServiceMock.self)
}

@Test private func generatedMockIsolatesGenericSpecializationsAndSupportsRethrows() throws {
    let mock = GenericServiceMock()
    var callbackValue = 0

    Given(mock).echo(.value("input")).willReturn("output")
    Given(mock).echo(.value(1)).willReturn(2)
    Given(mock).run().willReturn(42)
    Perform(mock).run { (callback: () throws -> Int) in callbackValue = (try? callback()) ?? -1 }

    #expect(mock.echo("input") == "output")
    #expect(mock.echo(1) == 2)
    #expect(try mock.run { () throws -> Int in 0 } == 42)
    #expect(callbackValue == 0)

    VerifyInOrder { order in
        order.expect(mock).echo(.value("input"))
        order.expect(mock).echo(.value(1))
        order.expect(mock).run(returning: Int.self)
    }
    Verify(mock, 1).echo(.value("input"))
    Verify(mock, 1).echo(.value(1))
    Verify(mock, 1).run(returning: Int.self)
    VerifyNoMoreInteractions(mock)
}

@Test private func generatedMockSupportsUnusedConstrainedPrimaryAssociatedType() {
    let mock = AssociatedOnlyMock<String>()
    let value: any AssociatedOnly<String> = mock
    _ = value
}

@Test private func generatedStaticGenericMethodsIsolateSpecializations() {
    Given(StaticGenericServiceMock.self).identity(.value("input")).willReturn("output")
    Given(StaticGenericServiceMock.self).identity(.value(1)).willReturn(2)

    #expect(StaticGenericServiceMock.identity("input") == "output")
    #expect(StaticGenericServiceMock.identity(1) == 2)
    VerifyInOrder { order in
        order.expect(StaticGenericServiceMock.self).identity(.value("input"))
        order.expect(StaticGenericServiceMock.self).identity(.value(1))
    }
    Verify(StaticGenericServiceMock.self, 1).identity(.value("input"))
    Verify(StaticGenericServiceMock.self, 1).identity(.value(1))
    VerifyNoMoreInteractions(StaticGenericServiceMock.self)
}

@Test @MainActor private func generatedGlobalActorMockKeepsConfigurationUsable() {
    let mock = MainActorServiceMock()
    Given(mock).title().willReturn("ready")
    Given(MainActorServiceMock.self).enabled.willReturn(true)

    #expect(mock.title() == "ready")
    #expect(MainActorServiceMock.enabled)
    Verify(mock, 1).title()
    Verify(MainActorServiceMock.self, 1).enabled()
}

@Test private func generatedMockSupportsStandaloneSelfRequirements() {
    let mock = SelfServiceMock()
    Given(mock).clone().willReturn(mock)
    Given(mock).isSame(as: .sameInstance(mock)).willReturn(true)
    Given(SelfServiceMock.self).make().willReturn(mock)

    #expect(mock.clone() === mock)
    #expect(mock.isSame(as: mock))
    #expect(SelfServiceMock.make() === mock)
    Verify(mock, 1).clone()
    Verify(mock, 1).isSame(as: .sameInstance(mock))
    Verify(SelfServiceMock.self, 1).make()
}

@Test private func generatedMockSnapshotsCopyableOwnershipParameters() {
    let mock = OwnershipServiceMock()
    Given(mock).borrow(.value("borrowed")).willReturn(1)
    Given(mock).consume(.value("consumed")).willReturn(2)
    Given(mock).send(.value("sent")).willReturn(3)

    #expect(mock.borrow("borrowed") == 1)
    #expect(mock.consume("consumed") == 2)
    #expect(mock.send("sent") == 3)
    Verify(mock, 1).borrow(.value("borrowed"))
    Verify(mock, 1).consume(.value("consumed"))
    Verify(mock, 1).send(.value("sent"))
}

@Test private func generatedUntypedThrowingMemberReturnsFrameworkErrorWhenUnstubbed() async {
    let mock = WeatherServiceMock()
    await #expect(throws: MockError.self) {
        try await mock.temperature(for: "Toronto")
    }
}

@Test private func generatedMockPreservesProtocolWhereAndDropsValueMutationModifier() {
    let mock = ProtocolWhereServiceMock<String>()
    Given(mock).update().willReturn(1)
    #expect(mock.update() == 1)
    Verify(mock, 1).update()
}

@Test private func generatedTransientMemberDoesNotRetainAndVerifiesCountOnly() {
    let mock = NoncopyableServiceMock()
    var inspected = 0
    Given(mock).inspect(.matching { $0.raw == 3 }).willProduce { 9 }
    Given(mock).consume(.value(2), token: .matching { $0.raw == 3 }).willProduce { 10 }
    Given(mock).make().willProduce { NoncopyableToken(raw: 4) }
    Given(mock).token.willProduce { NoncopyableToken(raw: 6) }
    Given(mock).token(set: .any)
    Given(mock).subscriptGet(.value(1)).willProduce { NoncopyableToken(raw: 8) }
    Given(mock).subscriptSet(.value(1), value: .any)
    Perform(mock).inspect(.any) { inspected = $0.raw }

    #expect(mock.inspect(NoncopyableToken(raw: 3)) == 9)
    #expect(mock.consume(2, token: NoncopyableToken(raw: 3)) == 10)
    let made = mock.make()
    let property = mock.token
    mock.token = NoncopyableToken(raw: 7)
    let indexed = mock[1]
    mock[1] = NoncopyableToken(raw: 9)
    #expect(made.raw == 4)
    #expect(property.raw == 6)
    #expect(indexed.raw == 8)
    #expect(inspected == 3)
    VerifyInOrder { order in
        order.expect(mock).inspect()
        order.expect(mock).consume(token: ())
        order.expect(mock).make()
        order.expect(mock).token()
        order.expect(mock).token(set: ())
        order.expect(mock).subscriptGet()
        order.expect(mock).subscriptSet()
    }
    Verify(mock, 1).inspect()
    Verify(mock, 1).consume(token: ())
    Verify(mock, 1).make()
    Verify(mock, 1).token()
    Verify(mock, 1).token(set: ())
    Verify(mock, 1).subscriptGet()
    Verify(mock, 1).subscriptSet()
    VerifyNoMoreInteractions(mock)

    let initialized = NoncopyableInitializerServiceMock(NoncopyableToken(raw: 5))
    Verify(initialized, 1).initializer()
    VerifyNoMoreInteractions(initialized)
    let genericInitialized = GenericNoncopyableInitializerServiceMock(NoncopyableToken(raw: 6))
    Verify(genericInitialized, 1).initializer(valueType: NoncopyableToken.self)
    VerifyNoMoreInteractions(genericInitialized)
}

@Test private func generatedEffectfulPropertiesAndStaticGenericSubscripts() async throws {
    let mock = EffectfulAccessorServiceMock()
    Given(mock).current.willReturn(8)
    Given(EffectfulAccessorServiceMock.self).subscriptGet(.value(2)).willReturn("two")
    Given(mock).subscriptGet(.value("key")).willReturn("value")

    #expect(try await mock.current == 8)
    #expect(EffectfulAccessorServiceMock[2] == "two")
    #expect(try await mock["key"] == "value")
    Verify(mock, 1).current()
    Verify(EffectfulAccessorServiceMock.self, 1).subscriptGet(.value(2))
    Verify(mock, 1).subscriptGet(.value("key"))

    let throwing = EffectfulAccessorServiceMock()
    Given(throwing).current
        .willAnswer { 1 }
        .thenThrow(.unavailable)
    Given(throwing).subscriptGet(.value("key"))
        .willAnswer { key in "answer-\(key)" }
        .thenThrow(LoadFailure.unavailable)
    #expect(try await throwing.current == 1)
    #expect(try await throwing["key"] == "answer-key")
    await #expect(throws: LoadFailure.unavailable) { try await throwing.current }
    await #expect(throws: LoadFailure.unavailable) { try await throwing["key"] }
    Verify(throwing, 2).current()
    Verify(throwing, 2).subscriptGet(.value("key"))
}

@Test private func generatedValuePackAndOpaqueParameterFactories() {
    let mock = PackAndOpaqueServiceMock(0, "seed")
    Given(mock).describe(.value(1), .value("a")).willReturn(2)
    Given(mock).identifier(.value(Identifier(id: 7))).willReturn(7)
    Given(mock).subscriptGet(.value(1), .value("a")).willReturn(3)

    #expect(mock.describe(1, "a") == 2)
    #expect(mock.identifier(Identifier(id: 7)) == 7)
    #expect(mock[1, "a"] == 3)
    Verify(mock, 1).initializer(.value(0), .value("seed"))
    Verify(mock, 1).describe(.value(1), .value("a"))
    Verify(mock, 1).identifier(.value(Identifier(id: 7)))
    Verify(mock, 1).subscriptGet(.value(1), .value("a"))
}

@Test private func generatedNonescapingCallbackActionsAreSynchronousAndRecordOtherArguments() {
    let mock = CallbackServiceMock()
    var received = 0
    Perform(mock).load(.value(4)) { key, completion in completion(key + 1) }

    mock.load(4) { received = $0 }
    #expect(received == 5)
    Verify(mock, 1).load(.value(4))

    var transformed = 0
    Perform(mock).transform(.value(6)) { value, completion in completion(value + 1) }
    mock.transform(6) { transformed = $0 }
    #expect(transformed == 7)
    Verify(mock, 1).transform(.value(6))

    var staticValue = ""
    Perform(CallbackServiceMock.self).load(.value("a")) { value, completion in completion(value + "b") }
    CallbackServiceMock.load("a") { staticValue = $0 }
    #expect(staticValue == "ab")
    Verify(CallbackServiceMock.self, 1).load(.value("a"))

    var combined = ""
    Perform(mock).combine { first, second in first(3); second("x") }
    mock.combine {
        combined += String($0)
    } second: {
        combined += $0
    }
    #expect(combined == "3x")
    Verify(mock, 1).combine()
}

@Test private func generatedEscapingCallbackMockCompilesAndRecordsInvocations() {
    let mock = EscapingCallbackServiceMock()
    Given(mock).fetch(completion: .any)

    mock.fetch { _ in }

    Verify(mock, 1).fetch(completion: .any)
}

@Test private func generatedDefaultPoliciesRelaxOnlyEligibleInstanceMembers() async throws {
    let voidMock = DefaultPolicyServiceMock(defaults: .void)
    voidMock.save(1)
    voidMock.value = 2
    voidMock["key"] = 3
    Verify(voidMock, 1).save(.value(1))
    Verify(voidMock, 1).value(set: .value(2))
    Verify(voidMock, 1).subscriptSet(.value("key"), value: .value(3))

    let optionalMock = DefaultPolicyServiceMock(defaults: .voidAndOptional)
    #expect(optionalMock.optionalResult() == nil)
    #expect(optionalMock.optionalValue == nil)
    #expect(optionalMock.swiftOptionalValue == nil)
    #expect(optionalMock.optionalClosure() == nil)
    await optionalMock.asyncSave()
    #expect(await optionalMock.asyncOptional() == nil)
    Verify(optionalMock, 1).optionalResult()
    Verify(optionalMock, 1).optionalValue()
    Verify(optionalMock, 1).swiftOptionalValue()
    Verify(optionalMock, 1).optionalClosure()
    Verify(optionalMock, 1).asyncSave()
    Verify(optionalMock, 1).asyncOptional()

    let requiredMock = AdvancedServiceMock(seed: 7, defaults: .void)
    requiredMock["key"] = 4
    Verify(requiredMock, 1).initializer(seed: .value(7))
    Verify(requiredMock, 1).subscriptSet(.value("key"), value: .value(4))

    resetMock(optionalMock)
    #expect(optionalMock.optionalResult() == nil)
    #expect(throws: MockError.unstubbed("throwingVoid")) {
        try optionalMock.throwingVoid()
    }
}

@Test @MainActor private func generatedMainActorAsyncDefaultPoliciesCompileAndReturnDefaults() async {
    let mock = DefaultPolicyServiceMock(defaults: .voidAndOptional)

    await mock.mainActorAsyncSave()
    #expect(await mock.mainActorAsyncOptional() == nil)
    #expect(await mock.mainActorAsyncOptionalValue == nil)
    #expect(await mock[true] == nil)

    Verify(mock, 1).mainActorAsyncSave()
    Verify(mock, 1).mainActorAsyncOptional()
    Verify(mock, 1).mainActorAsyncOptionalValue()
    Verify(mock, 1).subscriptGet(.value(true))
}

#if canImport(ObjectiveC)
    @Test private func generatedObjectiveCMockSubclassesNSObjectAndImplementsOptionalRequirements() {
        let mock = ObjectiveCServiceMock()
        Given(mock).fetch(.value(1)).willReturn("one")
        Given(mock).title.willReturn("title")

        #expect(mock.fetch(1) == "one")
        #expect(mock.title == "title")
        Verify(mock, 1).fetch(.value(1))
        Verify(mock, 1).title()
    }
#endif
