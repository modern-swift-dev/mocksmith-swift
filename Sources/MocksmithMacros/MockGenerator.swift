import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Validates a protocol and renders its generated mock implementation.
struct MockGenerator {
    let protocolDecl: ProtocolDeclSyntax
    let isActor: Bool
    let mockTypeOverride: String?
    let conformanceTypeOverride: String?
    let accessOverride: String?

    init(
        protocolDecl: ProtocolDeclSyntax,
        isActor: Bool,
        mockType: String? = nil,
        conformanceType: String? = nil,
        access: String? = nil
    ) {
        self.protocolDecl = protocolDecl
        self.isActor = isActor
        self.mockTypeOverride = mockType
        self.conformanceTypeOverride = conformanceType
        self.accessOverride = access
    }

    private var associatedTypes: [AssociatedTypeDeclSyntax] {
        protocolDecl.memberBlock.members.compactMap { $0.decl.as(AssociatedTypeDeclSyntax.self) }
    }

    private var replacements: [String: String] {
        Dictionary(uniqueKeysWithValues: associatedTypes.map { ($0.name.text, $0.name.text + "Type") })
    }

    private var mockType: String {
        mockTypeOverride ?? protocolDecl.name.text + "Mock"
    }

    private var conformanceType: String {
        conformanceTypeOverride ?? protocolDecl.name.text
    }

    private var isObjectiveC: Bool {
        hasAttribute(named: "objc", in: protocolDecl.attributes)
            || protocolDecl.inheritanceClause?.inheritedTypes.contains(where: { $0.type.trimmedDescription.hasSuffix("NSObjectProtocol") }) == true
    }

    private var hasGlobalActor: Bool {
        protocolDecl.attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return false
            }
            let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            return name.hasSuffix("Actor") && name != "Mockable"
        }
    }

    private var configurationIsolation: String {
        isActor || hasGlobalActor ? "nonisolated " : ""
    }

    private var access: String {
        if let accessOverride {
            return accessOverride
        }
        for modifier in protocolDecl.modifiers {
            let value = modifier.name.text
            if value == "private" || value == "fileprivate" {
                return "fileprivate "
            }
            if value == "public" || value == "package" {
                return value + " "
            }
        }
        return ""
    }

    private var members: [GeneratedMember] {
        var result: [GeneratedMember] = []
        for (index, item) in protocolDecl.memberBlock.members.enumerated() {
            if let function = item.decl.as(FunctionDeclSyntax.self) {
                result.append(.function(FunctionMember(declaration: function, index: index, access: access, replacements: replacements, mockType: mockType, factoryIsolation: configurationIsolation)))
            } else if let variable = item.decl.as(VariableDeclSyntax.self) {
                result
                    .append(contentsOf: PropertyMember.make(variable, index: index, access: access, replacements: replacements, mockType: mockType, factoryIsolation: configurationIsolation)
                        .map(GeneratedMember.property))
            } else if let subscriptDecl = item.decl.as(SubscriptDeclSyntax.self) {
                result
                    .append(contentsOf: SubscriptMember.make(subscriptDecl, index: index, access: access, replacements: replacements, mockType: mockType, factoryIsolation: configurationIsolation)
                        .map(GeneratedMember.subscriptMember))
            }
        }
        return result
    }

    func validate(in context: some MacroExpansionContext) -> Bool {
        var valid = true
        if protocolDecl.genericWhereClause?.trimmedDescription.contains("~Copyable") == true {
            diagnose("noncopyable associated-type constraints are not supported yet", at: protocolDecl, in: context)
            valid = false
        }
        for item in protocolDecl.memberBlock.members {
            if let associatedType = item.decl.as(AssociatedTypeDeclSyntax.self) {
                if associatedType.trimmedDescription.contains("~Copyable") {
                    diagnose("noncopyable associated types are not supported yet", at: associatedType, in: context)
                    valid = false
                }
                continue
            }
            if let function = item.decl.as(FunctionDeclSyntax.self) {
                let transient = hasAttribute(named: "MockNoncopyable", in: function.attributes) || function.trimmedDescription.contains("~Copyable")
                if transient, function.signature.parameterClause.parameters.contains(where: {
                    $0.type.trimmedDescription.contains("->") && !$0.trimmedDescription.contains("@escaping")
                }) {
                    diagnose("nonescaping closure parameters are not supported on noncopyable requirements", at: function, in: context)
                    valid = false
                } else if transient, function.signature.parameterClause.parameters.count > 1,
                          function.signature.parameterClause.parameters.contains(where: { $0.type.trimmedDescription.hasPrefix("borrowing ") }) {
                    diagnose("Swift 6.3 cannot form a transient aggregate containing a borrowed noncopyable parameter; use a single wrapper parameter", at: function, in: context)
                    valid = false
                } else if transient, function.signature.parameterClause.parameters.count > 1, function.genericParameterClause != nil {
                    diagnose("generic multiargument noncopyable requirements are not supported yet; use a named wrapper parameter", at: function, in: context)
                    valid = false
                } else if function.genericParameterClause?.parameters.contains(where: { $0.specifier != nil }) == true,
                          !(function.signature.parameterClause.parameters.count == 1 && function.signature.parameterClause.parameters.first?.type.trimmedDescription
                              .hasPrefix("repeat each ") == true) {
                    diagnose("parameter packs currently require one pack parameter", at: function, in: context)
                    valid = false
                } else if function.signature.returnClause?.type.trimmedDescription.contains("some ") == true {
                    diagnose("opaque result types are not valid protocol requirements", at: function, in: context)
                    valid = false
                }
                continue
            }
            if let initializer = item.decl.as(InitializerDeclSyntax.self) {
                if initializer.signature.parameterClause.parameters.contains(where: { ["defaults", "configure"].contains($0.firstName.text) }) {
                    diagnoseWarning(
                        "configuration initializer omitted because defaults: and configure: are reserved labels",
                        at: initializer,
                        in: context
                    )
                }
                if initializer.signature.parameterClause.parameters.contains(where: {
                    $0.type.trimmedDescription.contains("->") && !$0.trimmedDescription.contains("@escaping")
                }) {
                    diagnose("nonescaping initializer closures cannot be recorded", at: initializer, in: context)
                    valid = false
                }
                continue
            }
            if let variable = item.decl.as(VariableDeclSyntax.self) {
                if PropertyMember.isSupported(variable) {
                    continue
                }
            }
            if let subscriptDecl = item.decl.as(SubscriptDeclSyntax.self) {
                let settable = (subscriptDecl.accessorBlock?.trimmedDescription ?? "{ get }").contains("set")
                let hasValuePack = subscriptDecl.genericParameterClause?.parameters.contains(where: { $0.specifier != nil }) == true
                let transient = hasAttribute(named: "MockNoncopyable", in: subscriptDecl.attributes) || subscriptDecl.trimmedDescription.contains("~Copyable")
                if transient, subscriptDecl.parameterClause.parameters.contains(where: {
                    $0.type.trimmedDescription.contains("->") && !$0.trimmedDescription.contains("@escaping")
                }) {
                    diagnose("nonescaping closure parameters are not supported on noncopyable requirements", at: subscriptDecl, in: context)
                    valid = false
                    continue
                }
                if settable, hasValuePack {
                    diagnose("settable parameter-pack subscripts are not supported yet", at: subscriptDecl, in: context)
                    valid = false
                    continue
                }
                let transientFieldCount = subscriptDecl.parameterClause.parameters.count + (settable ? 1 : 0)
                if transient, subscriptDecl.genericParameterClause != nil, transientFieldCount > 1 {
                    diagnose("generic multiargument noncopyable subscripts cannot form a transient argument aggregate", at: subscriptDecl, in: context)
                    valid = false
                    continue
                }
                if SubscriptMember.isSupported(subscriptDecl) {
                    continue
                }
            }
            diagnose("@Mockable supports associated types, methods, properties, subscripts, and initializers", at: item.decl, in: context)
            valid = false
        }
        return valid
    }

    func render() -> String {
        let associated = associatedTypes
        let genericParts = associated.map { declaration -> String in
            let inherited = declaration.inheritanceClause?.inheritedTypes.map {
                rewriteType($0.type, replacements: replacements, mockType: mockType)
            }.joined(separator: " & ")
            let genericName = declaration.name.text + "Type"
            return genericName + (inherited.map { ": \($0)" } ?? "")
        }
        let generics = genericParts.isEmpty ? "" : "<\(genericParts.joined(separator: ", "))>"
        let whereRequirements = associated.compactMap(\.genericWhereClause?.requirements)
            + [protocolDecl.genericWhereClause?.requirements].compactMap(\.self)
        let combinedWhere = whereRequirements.map {
            rewriteType($0, replacements: replacements, mockType: mockType)
        }.joined(separator: ", ")
        let mockWhere = combinedWhere.isEmpty ? "" : " where " + combinedWhere
        let typealiases = associated.map { "    \(access)typealias \($0.name.text) = \($0.name.text)Type" }.joined(separator: "\n")
        let typealiasSection = typealiases.isEmpty ? "" : typealiases + "\n\n"
        let availability = protocolDecl.attributes.compactMap { element -> String? in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return nil
            }
            let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            return name == "available" || (name.hasSuffix("Actor") && name != "Mockable") ? attribute.trimmedDescription : nil
        }.joined(separator: "\n")
        let attributePrefix = availability.isEmpty ? "" : availability + "\n"
        let kind = isActor ? "actor" : "class"
        let isolation = configurationIsolation
        let all = members
        let initializers = protocolDecl.memberBlock.members.enumerated().compactMap { index, item in
            item.decl.as(InitializerDeclSyntax.self).map {
                InitializerMember(
                    declaration: $0,
                    index: index,
                    access: access,
                    replacements: replacements,
                    mockType: mockType,
                    factoryIsolation: configurationIsolation,
                    isActor: isActor,
                    isObjectiveC: isObjectiveC
                )
            }
        }
        let instance = all.filter { !$0.isStatic }
        let staticMembers = all.filter(\.isStatic)
        let genericMembers = instance.filter(\.usesRegistry)
        let memberChannels = all.filter { !$0.usesRegistry }.map { member in
            if member.isStatic {
                return "    \(isolation)private static var \(member.channelName): \(member.channelType) {\n        StaticMockRegistry.shared.member(owner: Self.self, key: \"\(member.channelName)\") { \(member.channelConstructor) }\n    }"
            }
            return "    \(isolation)private let \(member.channelName) = \(member.channelConstructor)"
        }
        let initializerChannels = initializers.filter { !$0.usesRegistry }.map { "    \(isolation)private let \($0.channelName) = \($0.channelType)(name: \"\($0.displayName)\")" }
        let argumentStructs = all.compactMap(\.argumentsStructDeclaration)
        let channels = (argumentStructs + memberChannels + initializerChannels).joined(separator: "\n")
        let initializerSignatures = Set(initializers.map(\.witnessCollisionKey))
        let initializerWitnesses = initializers.flatMap { initializer in
            let defaults = initializerSignatures.contains(initializer.defaultsCollisionKey) ? "" : initializer.defaultsWitness
            let configuration = initializerSignatures.contains(initializer.configurationCollisionKey) ? "" : initializer.configurationWitness
            return [initializer.witness, defaults, configuration]
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let memberWitnesses = all.map(\.witness).filter { !$0.isEmpty }
        let witnesses = (memberWitnesses + (initializerWitnesses.isEmpty ? [] : [initializerWitnesses])).joined(separator: "\n\n")
        let givenFactories = instance.map(\.givenFactory).joined(separator: "\n\n")
        let verifyFactories = (instance.map(\.verifyFactory) + initializers.map(\.verifyFactory)).joined(separator: "\n\n")
        let callsFactories = (instance.map(\.callsFactory) + initializers.map(\.callsFactory)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let stateFactories = instance.map(\.stateFactory).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let orderFactories = (instance.map(\.orderFactory) + initializers.map(\.orderFactory)).joined(separator: "\n\n")
        let performFactories = instance.map(\.performFactory).joined(separator: "\n\n")
        let staticGivenFactories = staticMembers.map(\.givenFactory).joined(separator: "\n\n")
        let staticVerifyFactories = staticMembers.map(\.verifyFactory).joined(separator: "\n\n")
        let staticCallsFactories = staticMembers.map(\.callsFactory).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let staticStateFactories = staticMembers.map(\.stateFactory).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let staticOrderFactories = staticMembers.map(\.orderFactory).joined(separator: "\n\n")
        let staticPerformFactories = staticMembers.map(\.performFactory).joined(separator: "\n\n")
        let resets = (instance.filter { !$0.usesRegistry }.map { "        \($0.channelName).reset(scopes)" } + initializers.filter { !$0.usesRegistry }
            .map { "        \($0.channelName).reset(scopes)" }).joined(separator: "\n")
        let channelSection = channels.isEmpty ? "" : channels + "\n\n"
        let givenSection = givenFactories.isEmpty ? "" : "\n\n" + givenFactories
        let verifySection = verifyFactories.isEmpty ? "" : "\n\n" + verifyFactories
        let orderSection = orderFactories.isEmpty ? "" : "\n\n" + orderFactories
        let performSection = performFactories.isEmpty ? "" : "\n\n" + performFactories
        let witnessSection = witnesses.isEmpty ? "" : "\n\n" + witnesses
        let resetSection = resets.isEmpty ? "" : "\n" + resets + "\n    "
        let needsGenericRegistry = !genericMembers.isEmpty || initializers.contains(where: \.usesRegistry)
        let genericRegistry = needsGenericRegistry ? "    \(isolation)private let _genericMockRegistry = GenericMockRegistry()\n\n" : ""
        let orderedChannels = instance.filter { !$0.usesRegistry }.map { "\($0.channelName).orderedInvocations" }
            + initializers.filter { !$0.usesRegistry }.map { "\($0.channelName).orderedInvocations" }
            + (needsGenericRegistry ? ["_genericMockRegistry.orderedInvocations"] : [])
        let orderedExpression = orderedChannels.isEmpty ? "[]" : orderedChannels.joined(separator: " + ")
        let orderedInvocations = "    fileprivate \(isolation)var _mocksmithOrderedInvocations: [_MocksmithInvocation] { \(orderedExpression) }\n\n"
        let unverifiedChannels = instance.filter { !$0.usesRegistry }.map { "\($0.channelName)._mocksmithUnverifiedInvocations" }
            + initializers.filter { !$0.usesRegistry }.map { "\($0.channelName)._mocksmithUnverifiedInvocations" }
            + (needsGenericRegistry ? ["_genericMockRegistry.unverifiedInvocations"] : [])
        let unverifiedExpression = unverifiedChannels.isEmpty ? "[]" : unverifiedChannels.joined(separator: " + ")
        let unverifiedInvocations = "    \(access)\(isolation)var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] { \(unverifiedExpression) }\n\n"
        let staticConformance = staticMembers.isEmpty ? "" : ", StaticMock, InOrderStaticMock, _MocksmithExhaustiveStaticMock, _MocksmithStaticCallInspectable, _MocksmithStaticStateControllable"
        let defaultPolicy = "    \(isolation)private let _mocksmithDefaultPolicy: MockDefaultPolicy\n\n"
        let defaultInitializer: String = if initializers.isEmpty {
            isObjectiveC
                ? "    \(access)override init() {\n        _mocksmithDefaultPolicy = .strict\n        super.init()\n    }\n\n    \(access)init(defaults: MockDefaultPolicy) {\n        _mocksmithDefaultPolicy = defaults\n        super.init()\n    }\n\n    \(access)init(defaults: MockDefaultPolicy = .strict, configure: (\(mockType)) -> Void) {\n        _mocksmithDefaultPolicy = defaults\n        super.init()\n        configure(self)\n    }\n\n"
                : "    \(access)init() { _mocksmithDefaultPolicy = .strict }\n\n    \(access)init(defaults: MockDefaultPolicy) { _mocksmithDefaultPolicy = defaults }\n\n    \(access)init(defaults: MockDefaultPolicy = .strict, configure: (\(mockType)) -> Void) {\n        _mocksmithDefaultPolicy = defaults\n        configure(self)\n    }\n\n"
        } else {
            ""
        }
        let staticDSL = staticMembers.isEmpty ? "" : """


            \(access)struct StaticGiven {
                fileprivate let mock: \(mockType).Type

        \(staticGivenFactories)
            }

            \(access)struct StaticVerify {
                fileprivate let mock: \(mockType).Type
                fileprivate let count: Count
                fileprivate let report: (VerificationResult) -> Void

        \(staticVerifyFactories)
            }

            \(access)struct StaticCalls {
                fileprivate let mock: \(mockType).Type

        \(staticCallsFactories)
            }

            \(access)struct StaticMockState {
                fileprivate let mock: \(mockType).Type

        \(staticStateFactories)
            }

            \(access)struct StaticOrderExpect {
                fileprivate let mock: \(mockType).Type
                fileprivate let order: InOrder

        \(staticOrderFactories)
            }

            \(access)struct StaticPerform {
                fileprivate let mock: \(mockType).Type

        \(staticPerformFactories)
            }

            \(access)\(isolation)static func given() -> StaticGiven { StaticGiven(mock: self) }
            \(access)\(isolation)static func _mocksmithStaticCalls() -> StaticCalls { StaticCalls(mock: self) }
            \(access)\(isolation)static func _mocksmithStaticState() -> StaticMockState { StaticMockState(mock: self) }
            \(access)\(isolation)static func perform() -> StaticPerform { StaticPerform(mock: self) }
            \(access)\(isolation)static func orderExpectations(in order: InOrder) -> StaticOrderExpect {
                StaticOrderExpect(mock: self, order: order)
            }
            \(access)\(isolation)static var _mocksmithUnverifiedInvocations: [_MocksmithInvocation] {
                StaticMockRegistry.shared.unverifiedInvocations(owner: Self.self)
            }
            \(access)\(isolation)static func verification(
                count: Count,
                report: @escaping (VerificationResult) -> Void
            ) -> StaticVerify {
                StaticVerify(mock: self, count: count, report: report)
            }
            \(access)\(isolation)static func resetMock(_ scopes: MockScope...) {
                StaticMockRegistry.shared.reset(owner: Self.self, scopes: scopes)
            }
        """

        let superclass = isObjectiveC ? "Foundation.NSObject, " : ""
        return attributePrefix + access + "final \(kind) \(mockType)\(generics): \(superclass)\(conformanceType), Mock, InOrderMock, _MocksmithExhaustiveMock, _MocksmithCallInspectable, _MocksmithStateControllable\(staticConformance)\(mockWhere) {\n"
            + typealiasSection
            + defaultPolicy
            + genericRegistry
            + orderedInvocations
            + unverifiedInvocations
            + channelSection
            + defaultInitializer
            + "    \(access)struct Given {\n"
            + "        fileprivate let mock: \(mockType)\(givenSection)\n"
            + "    }\n\n"
            + "    \(access)struct Verify {\n"
            + "        fileprivate let mock: \(mockType)\n"
            + "        fileprivate let count: Count\n"
            + "        fileprivate let report: (VerificationResult) -> Void\(verifySection)\n"
            + "    }\n\n"
            + "    \(access)struct Calls {\n"
            + "        fileprivate let mock: \(mockType)\(callsFactories.isEmpty ? "" : "\n\n" + callsFactories)\n"
            + "    }\n\n"
            + "    \(access)struct MockState {\n"
            + "        fileprivate let mock: \(mockType)\(stateFactories.isEmpty ? "" : "\n\n" + stateFactories)\n"
            + "    }\n\n"
            + "    \(access)struct OrderExpect {\n"
            + "        fileprivate let mock: \(mockType)\n"
            + "        fileprivate let order: InOrder\(orderSection)\n"
            + "    }\n\n"
            + "    \(access)struct Perform {\n"
            + "        fileprivate let mock: \(mockType)\(performSection)\n"
            + "    }\n\n"
            + "    \(access)\(isolation)func given() -> Given { Given(mock: self) }\n"
            + "    \(access)\(isolation)func _mocksmithCalls() -> Calls { Calls(mock: self) }\n"
            + "    \(access)\(isolation)func _mocksmithState() -> MockState { MockState(mock: self) }\n"
            + "    \(access)\(isolation)func perform() -> Perform { Perform(mock: self) }\n"
            + "    \(access)\(isolation)func orderExpectations(in order: InOrder) -> OrderExpect {\n"
            + "        OrderExpect(mock: self, order: order)\n"
            + "    }\n"
            + "    \(access)\(isolation)func verification(\n"
            + "        count: Count,\n"
            + "        report: @escaping (VerificationResult) -> Void\n"
            + "    ) -> Verify { Verify(mock: self, count: count, report: report) }\n"
            + "    \(access)\(isolation)func resetMock(_ scopes: MockScope...) {\(resetSection)\(needsGenericRegistry ? "\n        _genericMockRegistry.reset(scopes)" : "")\n    }"
            + staticDSL
            + witnessSection + "\n}"
    }

    func supportingMembers() -> [DeclSyntax] {
        let declaration = DeclSyntax(stringLiteral: render())
        let members: MemberBlockItemListSyntax
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            members = classDecl.memberBlock.members
        } else if let actorDecl = declaration.as(ActorDeclSyntax.self) {
            members = actorDecl.memberBlock.members
        } else {
            return []
        }
        return members.compactMap { item in
            if let variable = item.decl.as(VariableDeclSyntax.self),
               let identifier = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               identifier.hasPrefix("_mock_") || identifier == "_genericMockRegistry"
               || identifier == "_mocksmithOrderedInvocations"
               || identifier == "_mocksmithUnverifiedInvocations" {
                return item.decl
            }
            if let structure = item.decl.as(StructDeclSyntax.self),
               ["Given", "Verify", "Calls", "OrderExpect", "Perform", "StaticGiven", "StaticVerify", "StaticCalls", "StaticOrderExpect", "StaticPerform"].contains(structure.name.text) {
                return item.decl
            }
            if let function = item.decl.as(FunctionDeclSyntax.self),
               ["given", "_mocksmithCalls", "perform", "orderExpectations", "verification", "resetMock", "_mocksmithStaticCalls"].contains(function.name.text) {
                return item.decl
            }
            return nil
        }
    }

}
