import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Models generated channels, accessors, and factories for a subscript requirement.
/// Models generated channels, accessors, and factories for a subscript requirement.
///
/// Every value derived from the declaration is computed once in `init`; the
/// factories below read them many times while rendering.
struct SubscriptMember {
    enum Kind { case get, set }
    let declaration: SubscriptDeclSyntax
    let kind: Kind
    let index: Int
    let access: String
    let parameters: [ParameterInfo]
    let valueType: String
    let isReadWrite: Bool
    let factoryIsolation: String
    let replacements: [String: String]
    let mockType: String
    let getterHeader: String
    let availability: String
    let witnessAttributes: String
    let isOptionalResult: Bool
    let isVoidResult: Bool
    let isStatic: Bool
    let isTransient: Bool
    let opaqueParameters: [(name: String, constraint: String)]
    let isGeneric: Bool
    let usesRegistry: Bool
    let genericTypes: String
    let packGenericNames: [String]
    let genericClause: String
    let whereClause: String
    let signatureIdentifierSource: String
    let isAsync: Bool
    let isThrowing: Bool
    let typedError: String?
    let channelName: String
    let displayName: String
    let argumentsFieldCount: Int
    let argumentsType: String
    let outputType: String
    let channelType: String
    let matcherDeclarations: String

    init(
        declaration: SubscriptDeclSyntax,
        kind: Kind,
        index: Int,
        access: String,
        replacements: [String: String],
        mockType: String,
        factoryIsolation: String
    ) {
        self.declaration = declaration
        self.kind = kind
        self.index = index
        self.access = access
        self.replacements = replacements
        self.mockType = mockType
        self.factoryIsolation = factoryIsolation

        let declaredParameters = Array(declaration.parameterClause.parameters)
        var opaqueNamesByPosition: [Int: String] = [:]
        opaqueParameters = declaredParameters.enumerated().compactMap { position, parameter in
            let opaque = opaqueParameterType(parameter.type.trimmedDescription, position: position)
            opaqueNamesByPosition[position] = opaque?.name
            return opaque
        }
        parameters = declaredParameters.enumerated().map { position, parameter in
            let external = parameter.firstName.text
            let local = parameter.secondName?.text ?? (external == "_" ? "index\(position)" : external)
            var type = opaqueNamesByPosition[position]
                ?? rewriteType(parameter.type, replacements: replacements, mockType: mockType)
            if parameter.ellipsis != nil {
                type = "[\(type)]"
            }
            return ParameterInfo(external: external, local: local, type: type, matcher: "matching\(position)", position: position)
        }

        isReadWrite = hasSetter(declaration.accessorBlock)
        valueType = rewriteType(declaration.returnClause.type, replacements: replacements, mockType: mockType)
        isOptionalResult = isOptionalType(declaration.returnClause.type)
        isVoidResult = isVoidType(declaration.returnClause.type)
        let getter: AccessorDeclSyntax? = {
            guard let block = declaration.accessorBlock, case let .accessors(list) = block.accessors else {
                return nil
            }
            return list.first { $0.accessorSpecifier.text == "get" }
        }()
        getterHeader = getter.map(accessorHeader) ?? "get"
        let effects = DeclaredEffects(getter?.effectSpecifiers)
        isAsync = effects.isAsync
        isThrowing = effects.isThrowing
        typedError = effects.typedError
        availability = availabilityAttributes(declaration.attributes)
        witnessAttributes = witnessAttributePrefix(declaration.attributes, indentation: "    ")

        isStatic = declaration.modifiers.contains { ["static", "class"].contains($0.name.text) }
        isTransient = isTransientRequirement(declaration)
        isGeneric = declaration.genericParameterClause != nil || !opaqueParameters.isEmpty
        usesRegistry = isGeneric || !availability.isEmpty

        let genericParameters = declaration.genericParameterClause?.parameters
        genericTypes = ((genericParameters?.filter { $0.specifier == nil }.map { "\($0.name.text).self" } ?? [])
            + opaqueParameters.map { "\($0.name).self" }).joined(separator: ", ")
        packGenericNames = genericParameters?.compactMap { $0.specifier == nil ? nil : $0.name.text } ?? []
        let allGenerics = (genericParameters?.map(\.trimmedDescription) ?? []) + opaqueParameters.map { "\($0.name): \($0.constraint)" }
        genericClause = allGenerics.isEmpty ? "" : "<\(allGenerics.joined(separator: ", "))>"
        whereClause = declaration.genericWhereClause.map { " " + rewriteType($0, replacements: replacements, mockType: mockType) } ?? ""

        let modifiers = declaration.modifiers.map(\.trimmedDescription).filter { !["public", "package", "internal", "fileprivate", "private"].contains($0) }.joined(separator: " ")
        signatureIdentifierSource = [
            modifiers,
            declaration.genericParameterClause?.trimmedDescription ?? "",
            declaration.parameterClause.trimmedDescription,
            declaration.returnClause.trimmedDescription,
            declaration.genericWhereClause?.trimmedDescription ?? "",
            getterHeader
        ].joined(separator: "|")

        let kindName = kind == .get ? "get" : "set"
        channelName = "_mock_subscript_\(kindName)_\(stableIdentifier(signatureIdentifierSource))"
        displayName = "subscript.\(kindName)"
        argumentsFieldCount = parameters.count + (kind == .set ? 1 : 0)
        outputType = kind == .get ? valueType : "Void"
        matcherDeclarations = (parameters.map(\.declaration) + (kind == .set ? ["value: Parameter<\(valueType)>"] : [])).joined(separator: ", ")

        if isTransient, argumentsFieldCount > 1 {
            argumentsType = "_MockArguments_\(stableIdentifier(displayName + signatureIdentifierSource))"
        } else if kind == .get, parameters.count == 1, parameters[0].isPack {
            argumentsType = "(\(parameters[0].type))"
        } else {
            let fields = parameters.map { "\($0.local): \($0.type)" } + (kind == .set ? ["newValue: \(valueType)"] : [])
            argumentsType = switch fields.count {
                case 0: "Void"
                case 1: parameters[0].type
                default: "(" + fields.joined(separator: ", ") + ")"
            }
        }
        channelType = "\(isTransient ? "TransientMockMember" : "MockMember")<\(argumentsType), Void, \(outputType)>"
    }

    /// The setter counterpart of a getter member, sharing its declaration.
    private var setterMember: Self {
        Self(declaration: declaration, kind: .set, index: index, access: access, replacements: replacements, mockType: mockType, factoryIsolation: factoryIsolation)
    }

    var registrySetup: String {
        guard !packGenericNames.isEmpty else {
            return ""
        }
        var value = "var specializationTypeIDs: [ObjectIdentifier] = \(objectIdentifierList(genericTypes))\n            "
        for name in packGenericNames {
            value += "for type in repeat (each \(name)).self { specializationTypeIDs.append(ObjectIdentifier(type)) }\n            "
        }
        return value
    }

    var registryTypes: String {
        packGenericNames.isEmpty ? objectIdentifierList(genericTypes) : "specializationTypeIDs"
    }

    static func isSupported(_ declaration: SubscriptDeclSyntax) -> Bool {
        true
    }

    static func make(_ declaration: SubscriptDeclSyntax, index: Int, access: String, replacements: [String: String], mockType: String, factoryIsolation: String) -> [Self] {
        guard isSupported(declaration) else {
            return []
        }
        let getter = Self(declaration: declaration, kind: .get, index: index, access: access, replacements: replacements, mockType: mockType, factoryIsolation: factoryIsolation)
        return getter.isReadWrite ? [getter, getter.setterMember] : [getter]
    }

    var defaultFallback: String? {
        guard !isStatic, !isThrowing else {
            return nil
        }
        let policy = isAsync ? "_mocksmithDefaultPolicy" : "self._mocksmithDefaultPolicy"
        if kind == .set || isVoidResult {
            return "{ switch \(policy) { case .void, .voidAndOptional: (); case .strict: preconditionFailure(\"Unstubbed nonthrowing member subscript.get\") } }"
        }
        if isOptionalResult {
            return "{ switch \(policy) { case .voidAndOptional: nil; case .strict, .void: preconditionFailure(\"Unstubbed nonthrowing member subscript.get\") } }"
        }
        return nil
    }

    var channelConstructor: String {
        "\(channelType)(name: \"\(displayName)\")"
    }

    var registryResolution: String {
        guard usesRegistry else {
            return ""
        }
        if isStatic {
            return "\(registrySetup)let member: \(channelType) = StaticMockRegistry.shared.member(owner: mock, key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n            "
        }
        return "\(registrySetup)let member: \(channelType) = mock._genericMockRegistry.member(key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n            "
    }

    var witnessRegistryResolution: String {
        guard usesRegistry else {
            return ""
        }
        if isStatic {
            return "\(registrySetup)let member: \(channelType) = StaticMockRegistry.shared.member(owner: Self.self, key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n            "
        }
        return "\(registrySetup)let member: \(channelType) = _genericMockRegistry.member(key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n            "
    }

    var channelReference: String {
        usesRegistry ? "member" : "mock.\(channelName)"
    }

    var witnessChannelReference: String {
        usesRegistry ? "member" : channelName
    }

    var argumentsStructDeclaration: String? {
        guard isTransient, argumentsFieldCount > 1 else {
            return nil
        }
        let fields = parameters.map { ($0.local, $0.type) } + (kind == .set ? [("newValue", valueType)] : [])
        return "    \(access)struct \(argumentsType): ~Copyable {\n" + fields.map { "        let \($0.0): \($0.1)" }.joined(separator: "\n") + "\n    }"
    }

    var specificity: String {
        if kind == .get, parameters.count == 1, parameters[0].isPack {
            return "specificity"
        }
        let parts = parameters.map { "\($0.matcher).specificity" } + (kind == .set ? ["value.specificity"] : [])
        return parts.isEmpty ? "0" : parts.joined(separator: " + ")
    }

    var matcherClosure: String {
        if kind == .get, parameters.count == 1, let parameter = parameters.first, parameter.isPack {
            return "{ arguments in var result = true; for (argument, matcher) in repeat (each arguments, each \(parameter.matcher)) { result = result && matcher.matches(argument) }; return result }"
        }
        var parts = parameters.map { parameter in
            let argument = argumentsFieldCount == 1 ? "arguments" : "arguments.\(parameter.local)"
            return "\(parameter.matcher).matches(\(argument))"
        }
        if kind == .set {
            parts.append("value.matches(arguments.newValue)")
        }
        return parts.isEmpty ? "{ _ in true }" : "{ arguments in " + parts.joined(separator: " && ") + " }"
    }

    var invocationArguments: String {
        if isTransient, argumentsFieldCount > 1 {
            let fields = parameters.map { "\($0.local): \($0.local)" } + (kind == .set ? ["newValue: newValue"] : [])
            return "\(argumentsType)(\(fields.joined(separator: ", ")))"
        }
        if kind == .get, parameters.count == 1, parameters[0].isPack {
            return "(repeat each \(parameters[0].local))"
        }
        let fields = parameters.map { "\($0.local): \($0.local)" } + (kind == .set ? ["newValue: newValue"] : [])
        if fields.isEmpty {
            return "()"
        }
        if fields.count == 1 {
            return parameters[0].local
        }
        return "(" + fields.joined(separator: ", ") + ")"
    }

    var answerType: String {
        guard !parameters.contains(where: \.isPack) else {
            return "Never"
        }
        let ownership = isTransient ? "borrowing " : ""
        let effects = (isAsync ? " async" : "") + (isThrowing ? " throws" : "")
        return "(" + parameters.map { ownership + $0.type }.joined(separator: ", ") + ")\(effects) -> \(valueType)"
    }

    var answerAdapter: String {
        guard !parameters.contains(where: \.isPack) else {
            return "_mocksmithNoAnswer"
        }
        let values: [String] = if parameters.count == 1, parameters[0].isPack {
            ["repeat each arguments"]
        } else if parameters.count == 1 {
            ["arguments"]
        } else {
            parameters.map { "arguments.\($0.local)" }
        }
        let prefix = (isThrowing ? "try " : "") + (isAsync ? "await " : "")
        let runtimeParameters = isAsync ? "arguments" : "arguments, _"
        return "{ answer in .answering { \(runtimeParameters) in \(prefix)answer(\(values.joined(separator: ", "))) } }"
    }

    var witness: String {
        guard kind == .get else {
            return ""
        }
        let generics = genericClause
        let whereClause = declaration.genericWhereClause.map { rewriteType($0, replacements: replacements, mockType: mockType) } ?? ""
        let fallback = defaultFallback.map { ", unstubbed: \($0)" } ?? ""
        let defaultPolicySnapshot = isAsync && defaultFallback != nil
            ? "let _mocksmithDefaultPolicy = self._mocksmithDefaultPolicy\n            "
            : ""
        let call = "try \(isAsync ? "await " : "")\(witnessChannelReference).\(isAsync ? "invokeAsync" : "invoke")(\(invocationArguments)\(fallback))"
        let getterBody = if let typedError {
            "\(witnessRegistryResolution)do { return \(call) }\n            catch let error as \(typedError) { throw error }\n            catch { preconditionFailure(\"Invalid or unstubbed typed-throws member subscript.get: \\(error)\") }"
        } else if isThrowing {
            "\(witnessRegistryResolution)return \(call)"
        } else {
            "\(witnessRegistryResolution)\(defaultPolicySnapshot)do { return \(call) }\n            catch { preconditionFailure(\"Unstubbed nonthrowing member subscript.get: \\(error)\") }"
        }
        let getter = "\(getterHeader) {\n            \(getterBody)\n        }"
        let setterMember = self.setterMember
        let setterArgs = setterMember.invocationArguments
        let setterFallback = !isStatic ?
            ", unstubbed: { switch self._mocksmithDefaultPolicy { case .void, .voidAndOptional: (); case .strict: preconditionFailure(\"Unstubbed nonthrowing member subscript.set\") } }" : ""
        let setter = isReadWrite ?
            "\n        set {\n            \(setterMember.witnessRegistryResolution)do { return try \(setterMember.witnessChannelReference).invoke(\(setterArgs)\(setterFallback)) }\n            catch { preconditionFailure(\"Unstubbed nonthrowing member subscript.set: \\(error)\") }\n        }" :
            ""
        var parameterClause = rewriteType(declaration.parameterClause, replacements: replacements, mockType: mockType)
        for opaque in opaqueParameters {
            parameterClause.replaceFirst("some \(opaque.constraint)", with: opaque.name)
        }
        let modifiers = declaration.modifiers.map { $0.name.text == "class" ? "static" : $0.trimmedDescription }.filter { !["public", "package", "internal", "fileprivate", "private"].contains($0) }
            .joined(separator: " ")
        let prefix = availability.isEmpty ? "" : availability + "\n"
        return prefix + witnessAttributes + "    \(access)\(modifiers.isEmpty ? "" : modifiers + " ")subscript\(generics)\(parameterClause) -> \(valueType) \(whereClause){\n        \(getter)\(setter)\n    }"
    }

    var givenFactory: String {
        switch kind {
            case .get:
                if isAsync, !isTransient {
                    let failure = isThrowing ? (typedError ?? "any Error") : "Never"
                    let typeName = isThrowing ? "_MocksmithAsyncThrowingReturnStub" : "_MocksmithAsyncReturnStub"
                    let genericTypes = [argumentsType, "Void", valueType] + (isThrowing ? [failure] : []) + [answerType]
                    let handle = "\(typeName)<\(genericTypes.joined(separator: ", "))>"
                    let success = valueType == "Void"
                        ? "\(registryResolution)\(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: [.returnValue(())])\n                        "
                        : ""
                    return declaration(
                        "func subscriptGet\(genericClause)(\(factoryArguments(matcherDeclarations, inferredFrom: handle))) -> \(handle)\(whereClause)",
                        body: """
                        \(success)return \(handle)(
                            member: "\(displayName)",
                            apply: { outcomes in
                                \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                            },
                            answer: \(answerAdapter)
                        )
                        """,
                        attribute: valueType == "Void" ? "@discardableResult" : nil
                    )
                }
                if valueType == "Void" {
                    let successOutcome = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
                    let success = "\(registryResolution)\(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: \(successOutcome))"
                    guard isThrowing else {
                        return declaration(
                            "func subscriptGet\(genericClause)(\(factoryArguments(matcherDeclarations)))\(whereClause)",
                            body: success
                        )
                    }
                    let errorType = typedError ?? "any Error"
                    let prefix = isTransient
                        ? "_MocksmithThrowingProduceVoidStub"
                        : "_MocksmithThrowingVoidStub"
                    let handle = "\(prefix)<\(argumentsType), Void, \(errorType), Never>"
                    return declaration(
                        "func subscriptGet\(genericClause)(\(factoryArguments(matcherDeclarations, inferredFrom: handle))) -> \(handle)\(whereClause)",
                        body: """
                        \(success)
                        return \(handle)(
                            apply: { outcomes in
                                \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                            },
                            answer: _mocksmithNoAnswer
                        )
                        """,
                        attribute: "@discardableResult"
                    )
                }
                let typeName: String = if isTransient {
                    isThrowing ? "_MocksmithThrowingProduceStub" : "_MocksmithProduceStub"
                } else {
                    isThrowing ? "_MocksmithThrowingReturnStub" : "_MocksmithReturnStub"
                }
                let genericTypes = [argumentsType, "Void", valueType] + (isThrowing ? [typedError ?? "any Error"] : []) + [answerType]
                let handle = "\(typeName)<\(genericTypes.joined(separator: ", "))>"
                return declaration(
                    "func subscriptGet\(genericClause)(\(factoryArguments(matcherDeclarations, inferredFrom: handle))) -> \(handle)\(whereClause)",
                    body: """
                    return \(handle)(
                        apply: { outcomes in
                            \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                        },
                        answer: \(answerAdapter)
                    )
                    """
                )
            case .set:
                let outcomes = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
                return declaration(
                    "func subscriptSet\(genericClause)(\(factoryArguments(matcherDeclarations)))\(whereClause)",
                    body: "\(registryResolution)\(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: \(outcomes))"
                )
        }
    }

    var verifyFactory: String {
        let signature = "func \(kind == .get ? "subscriptGet" : "subscriptSet")\(genericClause)"
        if isTransient {
            return declaration(
                "\(signature)(\(factoryArguments("")))\(whereClause)",
                body: "\(registryResolution)report(\(channelReference).verification(count: count))"
            )
        }
        return declaration(
            "\(signature)(\(factoryArguments(matcherDeclarations)))\(whereClause)",
            body: "\(registryResolution)report(\(channelReference).verification(matching: \(matcherClosure), count: count))"
        )
    }

    var callsFactory: String {
        guard !isTransient else {
            return ""
        }
        let signature = "func \(kind == .get ? "subscriptGet" : "subscriptSet")\(genericClause)"
        return declaration(
            "\(signature)(\(factoryArguments(matcherDeclarations))) -> CallHistory<\(argumentsType)>\(whereClause)",
            body: "\(registryResolution)return \(channelReference).callHistory(matching: \(matcherClosure))"
        )
    }

    var orderFactory: String {
        let signature = "func \(kind == .get ? "subscriptGet" : "subscriptSet")\(genericClause)"
        let arguments = isTransient ? "" : matcherDeclarations
        let source = isStatic
            ? "sourceType: mock, invocations: { StaticMockRegistry.shared.orderedInvocations(owner: mock) }"
            : "source: mock, invocations: { mock._mocksmithOrderedInvocations }"
        let matches = isTransient
            ? "\(channelReference).matchesInvocation(sequence: sequence)"
            : "\(channelReference).matchesInvocation(sequence: sequence, matching: \(matcherClosure))"
        return declaration(
            "\(signature)(\(factoryArguments(arguments)))\(whereClause)",
            body: """
            \(registryResolution)order._append(
                \(source),
                member: "\(displayName)",
                matches: { sequence in \(matches) },
                markVerified: { sequence in \(channelReference)._mocksmithMarkVerified(sequence: sequence) }
            )
            """
        )
    }

    var performFactory: String {
        let ownership = isTransient ? "borrowing " : ""
        let actionTypes = parameters.map { ownership + $0.type } + (kind == .set ? [ownership + valueType] : [])
        let actionType = "(" + actionTypes.joined(separator: ", ") + ") -> Void"
        let actionArgs = kind == .get && parameters.count == 1 && parameters[0].isPack
            ? ["repeat each arguments"]
            : parameters.map { argumentsFieldCount == 1 ? "arguments" : "arguments.\($0.local)" } + (kind == .set ? ["arguments.newValue"] : [])
        let leading = matcherDeclarations.isEmpty ? "" : matcherDeclarations + ", "
        let outcomes = kind == .set ? (isTransient ? ", outcomes: [.producing { () }]" : ", outcomes: [.returnValue(())]") : ""
        let body = "\(registryResolution)\(channelReference).addAction(matching: \(matcherClosure), specificity: \(specificity)\(outcomes)) { arguments in action(\(actionArgs.joined(separator: ", "))) }"
        let actionLabel = parameters.contains(where: \.isPack) ? "perform action" : "_ action"
        return declaration(
            "func \(kind == .get ? "subscriptGet" : "subscriptSet")\(genericClause)(\(factoryArguments(leading + "\(actionLabel): @escaping \(actionType)")))\(whereClause)",
            body: body
        )
    }

    private func factoryArguments(_ arguments: String, inferredFrom: String = "") -> String {
        var usedReturningLabel = false
        let tokens = declaration.genericParameterClause?.parameters.compactMap { parameter -> String? in
            let name = parameter.name.text
            let inferenceSource = arguments + inferredFrom
            guard inferenceSource.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) == nil else {
                return nil
            }
            if parameter.specifier != nil {
                return "_ types: repeat (each \(name)).Type"
            }
            let appearsInOutput = valueType.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
            let label = appearsInOutput && !usedReturningLabel
                ? "returning"
                : name.prefix(1).lowercased() + String(name.dropFirst()) + "Type"
            if appearsInOutput {
                usedReturningLabel = true
            }
            return "\(label) _: \(name).Type"
        } ?? []
        return (tokens + (arguments.isEmpty ? [] : [arguments])).joined(separator: ", ")
    }

    private func declaration(_ signature: String, body: String, attribute: String? = nil) -> String {
        let setup = packMatcherSetup
        let attributePrefix = attribute.map { "        \($0)\n" } ?? ""
        return (availability.isEmpty ? "" : availability.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n")
            + attributePrefix
            + "        \(access)\(factoryIsolation)\(signature) {\n            \(setup)\(body)\n        }"
    }

    var packMatcherSetup: String {
        guard parameters.count == 1, let parameter = parameters.first, parameter.isPack else {
            return ""
        }
        return "var specificity = 0\n            for matcher in repeat each \(parameter.matcher) { specificity += matcher.specificity }\n            "
    }
}
