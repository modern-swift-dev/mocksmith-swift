#if os(macOS) || os(Linux)
    @testable import MocksmithMacros
    import SwiftSyntax
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    final class MockableMacroTests: XCTestCase {
        private let macros: [String: Macro.Type] = [
            "Mockable": MockableMacro.self,
            "MockNoncopyable": MockNoncopyableMacro.self
        ]

        func testRejectsNonProtocol() {
            assertMacroExpansion(
                """
                @Mockable
                struct Service {}
                """,
                expandedSource: """
                struct Service {}
                """,
                diagnostics: [
                    DiagnosticSpec(message: "@Mockable can only be attached to a protocol", line: 1, column: 1)
                ],
                macros: macros
            )
        }

        func testEmptyProtocol() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Empty {}
                """,
                expandedSource: """
                protocol Empty {}

                final class EmptyMock: Empty, Mock, InOrderMock, _MocksmithExhaustiveMock, _MocksmithCallInspectable, _MocksmithStateControllable {
                    private let _mocksmithDefaultPolicy: MockDefaultPolicy

                    fileprivate var _mocksmithOrderedInvocations: [_MocksmithInvocation] { [] }

                    var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] { [] }

                    init() { _mocksmithDefaultPolicy = .strict }

                    init(defaults: MockDefaultPolicy) { _mocksmithDefaultPolicy = defaults }

                    init(defaults: MockDefaultPolicy = .strict, configure: (EmptyMock) -> Void) {
                        _mocksmithDefaultPolicy = defaults
                        configure(self)
                    }

                    struct Given {
                        fileprivate let mock: EmptyMock
                    }

                    struct Verify {
                        fileprivate let mock: EmptyMock
                        fileprivate let count: Count
                        fileprivate let report: (VerificationResult) -> Void
                    }

                    struct Calls {
                        fileprivate let mock: EmptyMock
                    }

                    struct MockState {
                        fileprivate let mock: EmptyMock
                    }

                    struct OrderExpect {
                        fileprivate let mock: EmptyMock
                        fileprivate let order: InOrder
                    }

                    struct Perform {
                        fileprivate let mock: EmptyMock
                    }

                    func given() -> Given { Given(mock: self) }
                    func _mocksmithCalls() -> Calls { Calls(mock: self) }
                    func _mocksmithState() -> MockState { MockState(mock: self) }
                    func perform() -> Perform { Perform(mock: self) }
                    func orderExpectations(in order: InOrder) -> OrderExpect {
                        OrderExpect(mock: self, order: order)
                    }
                    func verification(
                        count: Count,
                        report: @escaping (VerificationResult) -> Void
                    ) -> Verify { Verify(mock: self, count: count, report: report) }
                    func resetMock(_ scopes: MockScope...) {
                    }
                }
                """,
                macros: macros
            )
        }

        func testDefersCustomProtocolInheritanceToBuildPlugin() {
            assertMacroExpansion(
                """
                protocol Parent {}
                @Mockable
                protocol Child: Parent {}
                """,
                expandedSource: """
                protocol Parent {}
                protocol Child: Parent {}
                """,
                macros: macros
            )
        }

        func testResolvedProtocolSurfaceGeneratesOriginalMock() throws {
            let source: DeclSyntax = """
            private protocol __MocksmithResolved_Service {
                func inherited(_ value: Int) -> String
                func own() -> Int
            }
            """
            let declaration = try XCTUnwrap(source.as(ProtocolDeclSyntax.self))
            let attribute: AttributeSyntax = "@_MocksmithResolved(Service.self, access: .public)"
            let context = BasicMacroExpansionContext(lexicalContext: [])
            let generated = try XCTUnwrap(
                ResolvedMockableMacro.expansion(
                    of: attribute,
                    providingPeersOf: declaration,
                    in: context
                ).first
            ).description

            XCTAssertTrue(generated.contains("public final class ServiceMock: Service, Mock"))
            XCTAssertTrue(generated.contains("public func inherited(_ value: Int) -> String"))
            XCTAssertTrue(generated.contains("public func own() -> Int"))
        }

        func testGenericMethodUsesRegistry() throws {
            let source = try peerSource(
                """
                protocol Service {
                    func echo<Value>(_ value: Value) -> Value
                }
                """
            )
            XCTAssertTrue(source.contains("MockMember<Value, Void, Value>"))
            XCTAssertTrue(source.contains("_MocksmithReturnStub<Value, Void, Value, (Value) -> Value>"))
            XCTAssertTrue(source.contains("typeIDs: [ObjectIdentifier(Value.self)]"))
            XCTAssertTrue(source.contains(".answering { arguments, ephemeral in answer(arguments) }"))
        }

        func testAnswerFactoriesMirrorArgumentsAndEffects() throws {
            let source = try peerSource(
                """
                protocol Service {
                    func format(_ value: Int, prefix: String) -> String
                    func fetch(_ key: String) async throws(ServiceError) -> Int
                    func greeting() -> String
                    func status() async -> String
                    func refresh() throws(ServiceError)
                    func refreshAsync() async throws(ServiceError)
                    var title: String { get throws(ServiceError) }
                    func resolve(_ key: Int, compute: () -> Int) -> Int
                    subscript(_ key: String) -> Int { get async throws(ServiceError) }
                }
                """
            )

            XCTAssertTrue(source.contains("(Int, String) -> String"))
            XCTAssertTrue(source.contains("(String) async throws -> Int"))
            XCTAssertTrue(source.contains("() -> String"))
            XCTAssertTrue(source.contains("() async -> String"))
            XCTAssertTrue(source.contains("() throws -> Void"))
            XCTAssertTrue(source.contains("() throws -> String"))
            XCTAssertTrue(source.contains("(Int, () -> Int) -> Int"))
            XCTAssertTrue(source.contains("(String) async throws -> Int"))
            XCTAssertTrue(source.contains("answer(arguments.value, arguments.prefix)"))
            XCTAssertTrue(source.contains("await answer(arguments)"))
            XCTAssertTrue(source.contains("answer(arguments, ephemeral)"))
            XCTAssertTrue(source.contains("answer()"))
            XCTAssertTrue(source.contains("_MocksmithThrowingVoidStub<Void, Void, ServiceError, () throws -> Void>"))
            XCTAssertTrue(source.contains("_MocksmithAsyncThrowingReturnStub<String, Void, Int, ServiceError, (String) async throws -> Int>"))
            XCTAssertTrue(source.contains("_MocksmithAsyncReturnStub<Void, Void, String, () async -> String>"))
            XCTAssertTrue(source.contains("_MocksmithAsyncThrowingReturnStub<Void, Void, Void, ServiceError, () async throws -> Void>"))
            XCTAssertTrue(source.contains("member: \"subscript.get\""))
        }

        func testSuspensionFactoriesCoverStaticGenericAndExcludeTransientMembers() throws {
            let source = try peerSource(
                """
                protocol Service {
                    static func load<Value>(_ value: Value) async -> Value
                    @MockNoncopyable func transient(_ value: borrowing Token) async -> Int
                }
                """
            )

            XCTAssertTrue(source.contains("_MocksmithAsyncReturnStub<Value, Void, Value, (Value) async -> Value>"))
            XCTAssertTrue(source.contains("StaticMockRegistry.shared.member"))
            XCTAssertTrue(source.contains("_MocksmithProduceStub<Token, Void, Int"))
            XCTAssertFalse(source.contains("_MocksmithAsyncReturnStub<Token"))
        }

        func testRethrowsUsesEphemeralClosureDispatcher() throws {
            let declaration: DeclSyntax = """
            protocol Service {
                func run<Value>(_ body: () throws -> Value) rethrows -> Value
            }
            """
            let protocolDecl = try XCTUnwrap(declaration.as(ProtocolDeclSyntax.self))
            let attribute: AttributeSyntax = "@Mockable"
            let context = BasicMacroExpansionContext(lexicalContext: [])

            let source = try XCTUnwrap(
                MockableMacro.expansion(of: attribute, providingPeersOf: protocolDecl, in: context).first
            ).description

            XCTAssertTrue(source.contains("MockMember<Void, () throws -> Value, Value>"))
            XCTAssertFalse(source.contains("EphemeralActionDispatcher"))
            XCTAssertTrue(source.contains("withoutActuallyEscaping(body)"))
            XCTAssertTrue(source.contains("func run<Value>(_ body: () throws -> Value) rethrows -> Value"))
            XCTAssertTrue(source.contains("func run<Value>() -> _MocksmithReturnStub<Void, () throws -> Value, Value, Never>"))
            XCTAssertTrue(source.contains("func run<Value>(_ action: @escaping (() throws -> Value) -> Void)"))
            XCTAssertTrue(source.contains("Invalid or unstubbed rethrows member"))
            XCTAssertFalse(source.contains("willThrow"))
            XCTAssertFalse(source.contains("Parameter<() throws -> Value>"))
        }

        func testMemberAvailabilityUsesRegistryAndPropagatesToFactories() throws {
            let source = try peerSource(
                """
                protocol Service {
                    @available(macOS 99, *)
                    func future() -> Int
                }
                """
            )
            XCTAssertTrue(source.contains("@available(macOS 99, *)\n        func future"))
            XCTAssertTrue(source.contains("_genericMockRegistry.member(key: \"_mock_future_0\", typeIDs: [])"))
            XCTAssertTrue(source.contains("_MocksmithReturnStub<Void, Void, Int, () -> Int>"))
        }

        func testValuePackAndOpaqueParameterGeneration() throws {
            let source = try peerSource(
                """
                protocol Service {
                    func pack<each Value>(_ values: repeat each Value) -> Int
                    func opaque(_ value: some Equatable) -> Int
                    subscript(_ key: some Hashable) -> String { get }
                }
                """
            )
            XCTAssertTrue(source.contains("repeat Parameter<each Value>"))
            XCTAssertTrue(source.contains("specializationTypeIDs.append(ObjectIdentifier(type))"))
            XCTAssertTrue(source.contains("func opaque<_MockOpaque0: Equatable>"))
            XCTAssertTrue(source.contains("subscript<_MockOpaque0: Hashable>(_ key: _MockOpaque0)"))
            XCTAssertTrue(source.contains("MockMember<_MockOpaque0, Void, String>"))
            XCTAssertTrue(source.contains("_MocksmithReturnStub<(repeat each Value), Void, Int, Never>"))
        }

        func testTransientMarkerUsesProducerAndCountOnlyVerification() throws {
            let source = try peerSource(
                """
                protocol Service: ~Copyable {
                    @MockNoncopyable
                    func make() -> Token
                }
                """
            )
            XCTAssertTrue(source.contains("TransientMockMember<Void, Void, Token>"))
            XCTAssertTrue(source.contains("func make() -> _MocksmithProduceStub<Void, Void, Token, () -> Token>"))
            XCTAssertTrue(source.contains("verification(count: count)"))
        }

        func testAssociatedTypesUseDistinctGenericParametersAndTypealiases() throws {
            let source = try peerSource(
                """
                protocol Repository<Element> {
                    associatedtype Element: Equatable
                    associatedtype Key where Key: Hashable
                    func load() -> Element
                }
                """
            )

            XCTAssertTrue(source.contains("RepositoryMock<ElementType: Equatable, KeyType>"))
            XCTAssertTrue(source.contains("where KeyType: Hashable"))
            XCTAssertTrue(source.contains("typealias Element = ElementType"))
            XCTAssertTrue(source.contains("typealias Key = KeyType"))
            XCTAssertTrue(source.contains("MockMember<Void, Void, ElementType>"))
        }

        func testStaticGenericMethodUsesTypedStaticRegistry() throws {
            let source = try peerSource(
                """
                protocol Factory {
                    static func make<Value: Equatable>(_ value: Value) -> Value where Value: Sendable
                }
                """
            )

            XCTAssertTrue(source.contains("StaticMock"))
            XCTAssertTrue(source.contains("StaticMockRegistry.shared.member(owner: mock, key: \"_mock_make_0\", typeIDs: [ObjectIdentifier(Value.self)])"))
            XCTAssertTrue(source.contains("static func make<Value: Equatable>"))
            XCTAssertTrue(source.contains("where Value: Sendable"))
            XCTAssertFalse(source.contains("_genericMockRegistry"))
        }

        func testGeneratedMocksExposeExhaustiveVerificationAndOrderMarkers() throws {
            let source = try peerSource(
                """
                public protocol Service {
                    static func load(_ value: Int)
                    var value: Int { get set }
                    subscript(_ key: String) -> Int { get set }
                }
                """
            )

            XCTAssertTrue(source
                .contains(
                    "public final class ServiceMock: Service, Mock, InOrderMock, _MocksmithExhaustiveMock, _MocksmithCallInspectable, _MocksmithStateControllable, StaticMock, InOrderStaticMock, _MocksmithExhaustiveStaticMock, _MocksmithStaticCallInspectable, _MocksmithStaticStateControllable"
                ))
            XCTAssertTrue(source.contains("public struct Calls"))
            XCTAssertTrue(source.contains("public struct StaticCalls"))
            XCTAssertTrue(source.contains("public init() { _mocksmithDefaultPolicy = .strict }"))
            XCTAssertTrue(source.contains("public init(defaults: MockDefaultPolicy) { _mocksmithDefaultPolicy = defaults }"))
            XCTAssertTrue(source.contains("public var _mocksmithUnverifiedInvocations: [_MocksmithInvocation]"))
            XCTAssertTrue(source.contains("public static var _mocksmithUnverifiedInvocations: [_MocksmithInvocation]"))
            XCTAssertTrue(source.contains("StaticMockRegistry.shared.unverifiedInvocations(owner: Self.self)"))
            XCTAssertTrue(source.contains("markVerified: { sequence in mock._mock_load_0._mocksmithMarkVerified(sequence: sequence) }"))
            XCTAssertTrue(source.contains("markVerified: { sequence in mock._mock_value_get_1._mocksmithMarkVerified(sequence: sequence) }"))
            XCTAssertTrue(source.contains("markVerified: { sequence in mock._mock_subscript_get_"))
        }

        func testDefaultPolicyGenerationUsesStructuralVoidAndAvoidsInitializerCollisions() throws {
            let source = try peerSource(
                """
                protocol Service {
                    init(seed: Int)
                    init(seed: Int, defaults: MockDefaultPolicy)
                    init<T>(value: T)
                    init<U>(value: U, defaults: MockDefaultPolicy)
                    init(_ defaults: Int)
                    var done: Swift.Void { get }
                    subscript(_ index: Int) -> (Void) { get }
                }
                """
            )

            XCTAssertFalse(source.contains("init(seed: Int, defaults _mocksmithDefaults: MockDefaultPolicy)"))
            XCTAssertFalse(source.contains("init<U>(value: U, defaults _mocksmithDefaults: MockDefaultPolicy)"))
            XCTAssertTrue(source.contains("init(_ defaults: Int, defaults _mocksmithDefaults: MockDefaultPolicy)"))
            XCTAssertTrue(source.contains("var done: Swift.Void"))
            XCTAssertTrue(source.contains(".invoke((), unstubbed:"))
            XCTAssertGreaterThanOrEqual(source.components(separatedBy: "case .void, .voidAndOptional").count - 1, 2)
        }

        func testAsyncDefaultPolicySnapshotsActorIsolatedStateForSendableFallback() throws {
            let source = try peerSource(
                """
                protocol Service {
                    @MainActor func save() async
                    @MainActor func value() async -> Int?
                    @MainActor var optionalValue: Int? { get async }
                    @MainActor subscript(_ key: Int) -> Int? { get async }
                }
                """
            )

            XCTAssertEqual(
                source.components(separatedBy: "let _mocksmithDefaultPolicy = self._mocksmithDefaultPolicy").count - 1,
                4
            )
            XCTAssertTrue(source.contains("invokeAsync((), unstubbed: { switch _mocksmithDefaultPolicy"))
            XCTAssertFalse(source.contains("invokeAsync((), unstubbed: { switch self._mocksmithDefaultPolicy"))
        }

        func testConfigurationInitializersMirrorRequiredInitializerEffects() throws {
            let source = try peerSource(
                """
                protocol Service {
                    init?<Value>(value: Value) async throws where Value: Sendable
                    init(configure: Int)
                }
                """
            )

            XCTAssertTrue(source
                .contains(
                    "init?<Value>(value: Value, defaults _mocksmithDefaults: MockDefaultPolicy = .strict, configure _mocksmithConfigure: (ServiceMock) -> Void) async throws where Value: Sendable"
                ))
            XCTAssertTrue(source.contains(".record(value)\n        _mocksmithConfigure(self)"))
            XCTAssertFalse(source.contains("init(configure: Int, defaults _mocksmithDefaults: MockDefaultPolicy = .strict, configure _mocksmithConfigure:"))
        }

        func testGeneratedMocksExposeTypedCallSelectors() throws {
            let source = try peerSource(
                """
                protocol Service {
                    init(seed: Int)
                    static func load<Value>(_ value: Value) -> Value
                    var value: Int { get set }
                    subscript(_ key: String) -> Int { get set }
                    @MockNoncopyable func transient(_ value: consuming Token)
                }
                """
            )

            XCTAssertTrue(source.contains("_MocksmithCallInspectable"))
            XCTAssertTrue(source.contains("_MocksmithStaticCallInspectable"))
            XCTAssertTrue(source.contains("func _mocksmithCalls() -> Calls"))
            XCTAssertTrue(source.contains("static func _mocksmithStaticCalls() -> StaticCalls"))
            XCTAssertTrue(source.contains("func initializer(seed matching0: Parameter<Int>) -> CallHistory<Int>"))
            XCTAssertTrue(source.contains("func value() -> CallHistory<Void>"))
            XCTAssertTrue(source.contains("func value(set matching: Parameter<Int>) -> CallHistory<Int>"))
            XCTAssertTrue(source.contains("func subscriptGet(_ matching0: Parameter<String>) -> CallHistory<String>"))
            XCTAssertTrue(source.contains("func subscriptSet(_ matching0: Parameter<String>, value: Parameter<Int>) -> CallHistory<(key: String, newValue: Int)>"))
            XCTAssertTrue(source.contains("func load<Value>(_ matching0: Parameter<Value>) -> CallHistory<Value>"))
            XCTAssertFalse(source.contains("func transient(_ matching0: Parameter<Token>) -> CallHistory"))
        }

        func testGlobalActorAndAvailabilityArePreservedWithNonisolatedConfiguration() throws {
            let source = try peerSource(
                """
                @MainActor
                @available(macOS 14, *)
                protocol Service {
                    func value() -> Int
                }
                """
            )

            XCTAssertTrue(source.hasPrefix("@MainActor\n@available(macOS 14, *)\nfinal class ServiceMock"))
            XCTAssertTrue(source.contains("nonisolated private let _mock_value_0"))
            XCTAssertTrue(source.contains("nonisolated func value"))
            XCTAssertTrue(source.contains("nonisolated func given"))
            XCTAssertTrue(source.contains("nonisolated func _mocksmithCalls"))
        }

        func testStandaloneSelfRewritesToConcreteMock() throws {
            let source = try peerSource(
                """
                protocol Copying {
                    func copy(_ other: Self) -> Self
                    static func make() -> Self
                }
                """
            )

            XCTAssertTrue(source.contains("MockMember<CopyingMock, Void, CopyingMock>"))
            XCTAssertTrue(source.contains("func copy(_ other: CopyingMock) -> CopyingMock"))
            XCTAssertTrue(source.contains("static func make() -> CopyingMock"))
        }

        func testRewritesKnownDependentSelfAssociatedType() throws {
            let source = try peerSource(
                """
                protocol Service {
                    associatedtype Value
                    func load() -> Self.Value
                }
                """
            )
            XCTAssertTrue(source.contains("MockMember<Void, Void, ValueType>"))
            XCTAssertTrue(source.contains("func load() -> ValueType"))
        }

        func testInitializersRecordSnapshotsAndExposeVerifyFactories() throws {
            let source = try peerSource(
                """
                protocol Service {
                    init(seed: Int, labels: String...)
                    init?(name: String)
                    init() async throws(ServiceError)
                }
                """
            )

            XCTAssertTrue(source.contains("MockMember<(seed: Int, labels: [String]), Void, Void>(name: \"initseed:labels:\")"))
            XCTAssertTrue(source.contains("required init(seed: Int, labels: String...)"))
            XCTAssertTrue(source.contains("_mock_initializer_0.record((seed: seed, labels: labels))"))
            XCTAssertTrue(source.contains("required init?(name: String)"))
            XCTAssertTrue(source.contains("_mock_initializer_1.record(name)"))
            XCTAssertTrue(source.contains("required init() async throws(ServiceError)"))
            XCTAssertTrue(source.contains("_mock_initializer_2.record(())"))
            XCTAssertTrue(source.contains("func initializer(seed matching0: Parameter<Int>, labels matching1: Parameter<[String]>)"))
            XCTAssertTrue(source.contains("func initializer(name matching0: Parameter<String>)"))
            XCTAssertTrue(source.contains("func initializer()"))
            XCTAssertTrue(source.contains("markVerified: { sequence in mock._mock_initializer_0._mocksmithMarkVerified(sequence: sequence) }"))
        }

        func testGenericInitializerUsesSpecializationRegistry() throws {
            let source = try peerSource(
                """
                protocol Service {
                    init<Value>(_ value: Value)
                }
                """
            )
            XCTAssertTrue(source.contains("_genericMockRegistry.member(key: \"_mock_initializer_0\", typeIDs: [ObjectIdentifier(Value.self)])"))
            XCTAssertTrue(source.contains("func initializer<Value>(_ matching0: Parameter<Value>)"))
        }

        func testOpaqueNoncopyableInitializerUsesSpecializationRegistry() throws {
            let source = try peerSource(
                """
                protocol Service: ~Copyable {
                    @MockNoncopyable init(_ value: consuming some ~Copyable)
                }
                """
            )
            XCTAssertTrue(source.contains("init<_MockOpaque0: ~Copyable>(_ value: consuming _MockOpaque0)"))
            XCTAssertTrue(source.contains("typeIDs: [ObjectIdentifier(_MockOpaque0.self)]"))
            XCTAssertTrue(source.contains("func initializer<_MockOpaque0: ~Copyable>(valueType _: _MockOpaque0.Type)"))
        }

        func testNonescapingFunctionParameterUsesEphemeralDispatcher() throws {
            let source = try peerSource(
                """
                protocol Service {
                    func load(_ key: Int, completion: (Int) -> Void)
                }
                """
            )
            XCTAssertTrue(source.contains("MockMember<Int, (Int) -> Void, Void>"))
            XCTAssertFalse(source.contains("EphemeralActionDispatcher"))
            XCTAssertTrue(source.contains("withoutActuallyEscaping(completion)"))
            XCTAssertTrue(source.contains("func load(_ matching0: Parameter<Int>, _ action: @escaping (Int, (Int) -> Void) -> Void)"))
        }

        func testEscapingClosureParameterIsRemovedFromInternalTypes() throws {
            let source = try peerSource(
                """
                protocol Service {
                    func fetch(completion: @escaping @MainActor @Sendable (Result<[String], Error>) -> Void)
                }
                """
            )
            XCTAssertTrue(source.contains("func fetch(completion: @escaping @MainActor @Sendable (Result<[String], Error>) -> Void)"))
            XCTAssertTrue(source.contains("MockMember<@MainActor @Sendable (Result<[String], Error>) -> Void, Void, Void>"))
            XCTAssertFalse(source.contains("MockMember<@escaping"))
        }

        func testPreservesAccessorEffects() throws {
            let source = try peerSource(
                """
                protocol Service {
                    var value: Int { get async throws }
                    subscript(_ key: String) -> Int { get async }
                }
                """
            )
            XCTAssertTrue(source.contains("get async throws"))
            XCTAssertTrue(source.contains("get async"))
        }

        func testDiagnosesSwiftInvalidNoncopyableAssociatedType() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service {
                    associatedtype Value: ~Copyable
                }
                """,
                expandedSource: """
                protocol Service {
                    associatedtype Value: ~Copyable
                }
                """,
                diagnostics: [
                    DiagnosticSpec(message: "noncopyable associated types are not supported yet", line: 3, column: 5)
                ],
                macros: macros
            )
        }

        func testDiagnosesBorrowedMultiargumentNoncopyableRequirement() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service: ~Copyable {
                    @MockNoncopyable
                    func inspect(_ token: borrowing Token, context: Int) -> Int
                }
                """,
                expandedSource: """
                protocol Service: ~Copyable {
                    func inspect(_ token: borrowing Token, context: Int) -> Int
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message: "Swift 6.3 cannot form a transient aggregate containing a borrowed noncopyable parameter; use a single wrapper parameter",
                        line: 3,
                        column: 5
                    )
                ],
                macros: macros
            )
        }

        func testDiagnosesNonescapingClosureOnNoncopyableRequirement() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service: ~Copyable {
                    @MockNoncopyable
                    func run(_ body: () -> Void)
                }
                """,
                expandedSource: """
                protocol Service: ~Copyable {
                    func run(_ body: () -> Void)
                }
                """,
                diagnostics: [
                    DiagnosticSpec(message: "nonescaping closure parameters are not supported on noncopyable requirements", line: 3, column: 5)
                ],
                macros: macros
            )
        }

        func testDiagnosesSettableParameterPackSubscript() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service {
                    subscript<each Value>(_ values: repeat each Value) -> Int { get set }
                }
                """,
                expandedSource: """
                protocol Service {
                    subscript<each Value>(_ values: repeat each Value) -> Int { get set }
                }
                """,
                diagnostics: [
                    DiagnosticSpec(message: "settable parameter-pack subscripts are not supported yet", line: 3, column: 5)
                ],
                macros: macros
            )
        }

        func testDiagnosesGenericSettableNoncopyableSubscript() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service: ~Copyable {
                    @MockNoncopyable
                    subscript<Value>(_ value: Value) -> Token { get set }
                }
                """,
                expandedSource: """
                protocol Service: ~Copyable {
                    subscript<Value>(_ value: Value) -> Token { get set }
                }
                """,
                diagnostics: [
                    DiagnosticSpec(message: "generic multiargument noncopyable subscripts cannot form a transient argument aggregate", line: 3, column: 5)
                ],
                macros: macros
            )
        }

        func testDiagnosesGenericReadOnlyMultiargumentNoncopyableSubscript() {
            assertMacroExpansion(
                """
                @Mockable
                protocol Service: ~Copyable {
                    @MockNoncopyable
                    subscript<Value>(_ value: Value, fallback: Int) -> Token { get }
                }
                """,
                expandedSource: """
                protocol Service: ~Copyable {
                    subscript<Value>(_ value: Value, fallback: Int) -> Token { get }
                }
                """,
                diagnostics: [
                    DiagnosticSpec(message: "generic multiargument noncopyable subscripts cannot form a transient argument aggregate", line: 3, column: 5)
                ],
                macros: macros
            )
        }

        func testPreservesNonisolatedPropertyModifier() throws {
            let source = try peerSource(
                """
                protocol Service: Actor {
                    nonisolated var name: String { get }
                }
                """
            )
            XCTAssertTrue(source.contains("nonisolated var name: String"))
        }

        func testObjectiveCZeroArgumentInitializerOverridesNSObject() throws {
            let source = try peerSource(
                """
                @objc protocol Service {
                    init()
                }
                """
            )
            XCTAssertTrue(source.contains("final class ServiceMock: Foundation.NSObject, Service, Mock"))
            XCTAssertTrue(source.contains("required override init()"))
        }

        func testInitializerAvailabilityPropagatesToVerifyFactory() throws {
            let source = try peerSource(
                """
                protocol Service {
                    @available(macOS 99, *)
                    init(value: Int)
                }
                """
            )
            XCTAssertTrue(source.contains("@available(macOS 99, *)\n        func initializer(value matching0: Parameter<Int>)"))
        }

        func testGenericReturnOnlySubscriptFactoriesHaveMetatypeToken() throws {
            let source = try peerSource(
                """
                protocol Service {
                    subscript<Value>(_ key: String) -> Value { get }
                }
                """
            )
            XCTAssertTrue(source.contains("func subscriptGet<Value>(_ matching0: Parameter<String>) -> _MocksmithReturnStub<String, Void, Value, (String) -> Value>"))
            XCTAssertTrue(source.contains("func subscriptGet<Value>(returning _: Value.Type, _ matching0: Parameter<String>)"))
            XCTAssertTrue(source.contains("func subscriptGet<Value>(returning _: Value.Type, _ matching0: Parameter<String>, _ action: @escaping (String) -> Void)"))
        }

        private func peerSource(_ source: DeclSyntax, file: StaticString = #filePath, line: UInt = #line) throws -> String {
            let declaration = try XCTUnwrap(source.as(ProtocolDeclSyntax.self), file: file, line: line)
            let attribute: AttributeSyntax = "@Mockable"
            let context = BasicMacroExpansionContext(lexicalContext: [])
            return try XCTUnwrap(
                MockableMacro.expansion(of: attribute, providingPeersOf: declaration, in: context).first,
                file: file,
                line: line
            ).description
        }

    }
#endif
