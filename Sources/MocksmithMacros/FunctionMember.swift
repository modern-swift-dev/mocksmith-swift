import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Models generated channels, witnesses, and factories for a function requirement.
struct FunctionMember {
    let declaration: FunctionDeclSyntax
    let index: Int
    let access: String
    let replacements: [String: String]
    let mockType: String
    let factoryIsolation: String

    var name: String {
        declaration.name.text
    }

    var channelName: String {
        "_mock_\(name.replacingOccurrences(of: "`", with: ""))_\(index)"
    }

    var displayName: String {
        declaration.name.text + declaration.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
    }

    var parameters: [ParameterInfo] {
        declaration.signature.parameterClause.parameters.enumerated().compactMap { position, parameter in
            if parameter.type.trimmedDescription.contains("->"), !parameter.trimmedDescription.contains("@escaping") {
                return nil
            }
            let external = parameter.firstName.text
            let local = parameter.secondName?.text ?? (external == "_" ? "argument\(position)" : external)
            var type = opaqueParameter(at: position)?.name
                ?? strippingEscapingAttribute(from: rewriteType(parameter.type.trimmedDescription, replacements: replacements, mockType: mockType))
            if parameter.ellipsis != nil {
                type = "[\(type)]"
            }
            for prefix in ["inout ", "borrowing ", "consuming ", "sending "] where type.hasPrefix(prefix) {
                type.removeFirst(prefix.count)
            }
            return ParameterInfo(external: external, local: local, type: type, matcher: "matching\(position)", position: position)
        }
    }

    var ephemeralParameters: [(local: String, type: String)] {
        declaration.signature.parameterClause.parameters.enumerated().compactMap { position, parameter -> (String, String)? in
            guard parameter.type.trimmedDescription.contains("->"), !parameter.trimmedDescription.contains("@escaping") else {
                return nil
            }
            let external = parameter.firstName.text
            let local = parameter.secondName?.text ?? (external == "_" ? "argument\(position)" : external)
            return (local, rewriteType(parameter.type.trimmedDescription, replacements: replacements, mockType: mockType))
        }
    }

    var hasEphemeralDispatcher: Bool {
        !ephemeralParameters.isEmpty
    }

    var ephemeralArgumentsType: String {
        if ephemeralParameters.isEmpty {
            return "Void"
        }
        if ephemeralParameters.count == 1 {
            return ephemeralParameters[0].type
        }
        return "(" + ephemeralParameters.map { "\($0.local): \($0.type)" }.joined(separator: ", ") + ")"
    }

    var argumentsType: String {
        if isTransient, parameters.count > 1 {
            return "_MockArguments_\(stableIdentifier(displayName))"
        }
        if parameters.count == 1, parameters[0].isPack {
            return "(\(parameters[0].type))"
        }
        return switch parameters.count {
            case 0: "Void"
            case 1: parameters[0].type
            default: "(" + parameters.map { "\($0.local): \($0.type)" }.joined(separator: ", ") + ")"
        }
    }

    var argumentsExpression: String {
        if isTransient, parameters.count > 1 {
            return "\(argumentsType)(" + parameters.map { "\($0.local): \($0.local)" }.joined(separator: ", ") + ")"
        }
        if parameters.count == 1, parameters[0].isPack {
            return "(repeat each \(parameters[0].local))"
        }
        return switch parameters.count {
            case 0: "()"
            case 1: parameters[0].local
            default: "(" + parameters.map { "\($0.local): \($0.local)" }.joined(separator: ", ") + ")"
        }
    }

    var outputType: String {
        declaration.signature.returnClause.map { rewriteType($0.type.trimmedDescription, replacements: replacements, mockType: mockType) } ?? "Void"
    }

    var defaultFallback: String? {
        guard !isStatic, !isThrowing, !isRethrows else {
            return nil
        }
        let policy = isAsync ? "_mocksmithDefaultPolicy" : "self._mocksmithDefaultPolicy"
        if declaration.signature.returnClause.map({ isVoidType($0.type) }) ?? true {
            return "{ switch \(policy) { case .void, .voidAndOptional: (); case .strict: preconditionFailure(\"Unstubbed nonthrowing member \(displayName)\") } }"
        }
        if let returnType = declaration.signature.returnClause?.type, isOptionalType(returnType) {
            return "{ switch \(policy) { case .voidAndOptional: nil; case .strict, .void: preconditionFailure(\"Unstubbed nonthrowing member \(displayName)\") } }"
        }
        return nil
    }

    var isStatic: Bool {
        declaration.modifiers.contains { ["static", "class"].contains($0.name.text) }
    }

    var opaqueParameters: [(name: String, constraint: String)] {
        declaration.signature.parameterClause.parameters.enumerated().compactMap { position, parameter in
            opaqueParameterType(parameter.type.trimmedDescription, position: position)
        }
    }

    func opaqueParameter(at position: Int) -> (name: String, constraint: String)? {
        opaqueParameters.first { $0.name == "_MockOpaque\(position)" }
    }

    var isGeneric: Bool {
        declaration.genericParameterClause != nil || !opaqueParameters.isEmpty
    }

    var availability: String {
        availabilityAttributes(declaration.attributes)
    }

    var usesRegistry: Bool {
        isGeneric || !availability.isEmpty
    }

    var isRethrows: Bool {
        (declaration.signature.effectSpecifiers?.trimmedDescription ?? "").contains("rethrows")
    }

    var isThrowing: Bool {
        (declaration.signature.effectSpecifiers?.trimmedDescription ?? "").contains("throws")
    }

    var isAsync: Bool {
        (declaration.signature.effectSpecifiers?.trimmedDescription ?? "").contains("async")
    }

    var isTransient: Bool {
        hasAttribute(named: "MockNoncopyable", in: declaration.attributes) || declaration.trimmedDescription.contains("~Copyable")
    }

    var genericClause: String {
        let explicit = declaration.genericParameterClause?.parameters.map(\.trimmedDescription) ?? []
        let opaque = opaqueParameters.map { "\($0.name): \($0.constraint)" }
        let all = explicit + opaque
        return all.isEmpty ? "" : "<\(all.joined(separator: ", "))>"
    }

    var whereClause: String {
        declaration.genericWhereClause.map { " " + rewriteType($0.trimmedDescription, replacements: replacements, mockType: mockType) } ?? ""
    }

    var genericTypes: String {
        ((declaration.genericParameterClause?.parameters.filter { $0.specifier == nil }.map { "\($0.name.text).self" } ?? []) + opaqueParameters.map { "\($0.name).self" }).joined(separator: ", ")
    }

    var packGenericNames: [String] {
        declaration.genericParameterClause?.parameters.compactMap { $0.specifier == nil ? nil : $0.name.text } ?? []
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
            return "\(registrySetup.replacingOccurrences(of: "            ", with: "        "))let member: \(channelType) = StaticMockRegistry.shared.member(owner: Self.self, key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n        "
        }
        return "\(registrySetup.replacingOccurrences(of: "            ", with: "        "))let member: \(channelType) = _genericMockRegistry.member(key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelConstructor) }\n        "
    }

    var channelType: String {
        "\(isTransient ? "TransientMockMember" : "MockMember")<\(argumentsType), \(ephemeralArgumentsType), \(outputType)>"
    }

    var channelConstructor: String {
        "\(channelType)(name: \"\(displayName)\")"
    }

    var channelReference: String {
        usesRegistry ? "member" : "mock.\(channelName)"
    }

    var argumentsStructDeclaration: String? {
        guard isTransient, parameters.count > 1 else {
            return nil
        }
        return "    \(access)struct \(argumentsType): ~Copyable {\n" + parameters.map { "        let \($0.local): \($0.type)" }.joined(separator: "\n") + "\n    }"
    }

    var typedError: String? {
        let effects = declaration.signature.effectSpecifiers?.trimmedDescription ?? ""
        guard let start = effects.range(of: "throws("), let end = effects[start.upperBound...].firstIndex(of: ")") else {
            return nil
        }
        let type = String(effects[start.upperBound ..< end]).trimmingCharacters(in: .whitespaces)
        return ["Error", "any Error", "any Swift.Error"].contains(type) ? nil : type
    }

    var matcherDeclarations: String {
        parameters.map(\.declaration).joined(separator: ", ")
    }

    var matcherClosure: String {
        guard !parameters.isEmpty else {
            return "{ _ in true }"
        }
        if parameters.count == 1, let parameter = parameters.first, parameter.isPack {
            return "{ arguments in var result = true; for (argument, matcher) in repeat (each arguments, each \(parameter.matcher)) { result = result && matcher.matches(argument) }; return result }"
        }
        return "{ arguments in " + parameters.map { parameter in
            let access = parameters.count == 1 ? "arguments" : "arguments.\(parameter.local)"
            return "\(parameter.matcher).matches(\(access))"
        }.joined(separator: " && ") + " }"
    }

    var specificity: String {
        if parameters.count == 1, parameters[0].isPack {
            return "specificity"
        }
        return parameters.isEmpty ? "0" : parameters.map { "\($0.matcher).specificity" }.joined(separator: " + ")
    }

    var matcherSetup: String {
        guard parameters.count == 1, let parameter = parameters.first, parameter.isPack else {
            return ""
        }
        return "var specificity = 0\n            for matcher in repeat each \(parameter.matcher) { specificity += matcher.specificity }\n            "
    }

    var actionType: String {
        let ownership = isTransient ? "borrowing " : ""
        return switch parameters.count {
            case 0: "() -> Void"
            case 1 where parameters[0].isPack: "(\(parameters[0].type)) -> Void"
            case 1: "(\(ownership)\(parameters[0].type)) -> Void"
            default: "(" + parameters.map { ownership + $0.type }.joined(separator: ", ") + ") -> Void"
        }
    }

    var actionCall: String {
        switch parameters.count {
            case 0: "action()"
            case 1 where parameters[0].isPack: "action(repeat each arguments)"
            case 1: "action(arguments)"
            default: "action(" + parameters.map { "arguments.\($0.local)" }.joined(separator: ", ") + ")"
        }
    }

    var supportsAnswer: Bool {
        guard !isRethrows, !parameters.contains(where: \.isPack) else {
            return false
        }
        return true
    }

    var answerType: String {
        guard supportsAnswer else {
            return "Never"
        }
        let ownership = isTransient ? "borrowing " : ""
        let types = parameters.map { ownership + $0.type } + (isAsync ? [] : ephemeralParameters.map(\.type))
        let effects = if isAsync, isThrowing {
            " async throws"
        } else if isAsync {
            " async"
        } else if isThrowing {
            " throws"
        } else {
            ""
        }
        return "(" + types.joined(separator: ", ") + ")\(effects) -> \(outputType)"
    }

    var answerAdapter: String {
        guard supportsAnswer else {
            return "_mocksmithNoAnswer"
        }
        let retained: [String] = switch parameters.count {
            case 0: []
            case 1 where parameters[0].isPack: ["repeat each arguments"]
            case 1: ["arguments"]
            default: parameters.map { "arguments.\($0.local)" }
        }
        let ephemeral = isAsync ? [] : ephemeralParameters.map {
            ephemeralParameters.count == 1 ? "ephemeral" : "ephemeral.\($0.local)"
        }
        let prefix = (isThrowing ? "try " : "") + (isAsync ? "await " : "")
        let runtimeParameters = isAsync ? "arguments" : "arguments, ephemeral"
        return "{ answer in .answering { \(runtimeParameters) in \(prefix)answer(\((retained + ephemeral).joined(separator: ", "))) } }"
    }

    var signaturePrefix: String {
        let modifiers = declaration.modifiers.compactMap { modifier -> String? in
            if ["mutating", "nonmutating", "optional"].contains(modifier.name.text) {
                return nil
            }
            return modifier.name.text == "class" ? "static" : modifier.trimmedDescription
        }.joined(separator: " ")
        return access + (modifiers.isEmpty ? "" : modifiers + " ")
    }

    var witness: String {
        var signatureText = rewriteType(declaration.signature.trimmedDescription, replacements: replacements, mockType: mockType)
        for opaque in opaqueParameters {
            if let range = signatureText.range(of: "some \(opaque.constraint)") {
                signatureText.replaceSubrange(range, with: opaque.name)
            }
        }
        let signature = "\(signaturePrefix)func \(declaration.name.trimmedDescription)\(genericClause)\(signatureText)\(whereClause)"
        let channel = usesRegistry ? "member" : channelName
        let awaitPrefix = isAsync ? "await " : ""
        let ephemeralValue = ephemeralParameters.count == 1
            ? "_ephemeral0"
            : "(" + ephemeralParameters.enumerated().map { "\($0.element.local): _ephemeral\($0.offset)" }.joined(separator: ", ") + ")"
        let invokeName = isAsync ? "invokeAsync" : "invoke"
        let fallback = defaultFallback.map { ", unstubbed: \($0)" } ?? ""
        let defaultPolicySnapshot = isAsync && defaultFallback != nil
            ? "let _mocksmithDefaultPolicy = self._mocksmithDefaultPolicy\n        "
            : ""
        var invocation = "try \(awaitPrefix)\(channel).\(invokeName)(\(argumentsExpression)\(hasEphemeralDispatcher ? ", ephemeral: \(ephemeralValue)" : "")\(fallback))"
        for (offset, parameter) in ephemeralParameters.enumerated().reversed() {
            invocation = "try \(awaitPrefix)withoutActuallyEscaping(\(parameter.local)) { _ephemeral\(offset) in \(invocation) }"
        }
        let attributes = witnessAttributePrefix(declaration.attributes, indentation: "    ")
        if let typedError {
            return availabilityPrefix(indentation: "    ") + attributes + """
                \(signature) {
                    \(witnessRegistryResolution)\
                    do { return \(invocation) }
                    catch let error as \(typedError) { throw error }
                    catch { preconditionFailure("Invalid or unstubbed typed-throws member \(displayName): \\(error)") }
                }
            """.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        if isRethrows {
            return availabilityPrefix(indentation: "    ") + attributes + """
                \(signature) {
                    \(witnessRegistryResolution)\
                    do { return \(invocation) }
                    catch { preconditionFailure("Invalid or unstubbed rethrows member \(displayName): \\(error)") }
                }
            """.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        if isThrowing {
            return availabilityPrefix(indentation: "    ") + attributes + "    \(signature) {\n        \(witnessRegistryResolution)return \(invocation)\n    }"
        }
        return availabilityPrefix(indentation: "    ") + attributes + """
            \(signature) {
                \(witnessRegistryResolution)\(defaultPolicySnapshot)do { return \(invocation) }
                catch { preconditionFailure("Unstubbed nonthrowing member \(displayName): \\(error)") }
            }
        """.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    var givenFactory: String {
        if isAsync, !isTransient, !isRethrows {
            let failure = isThrowing ? (typedError ?? "any Error") : "Never"
            let typeName = isThrowing ? "_MocksmithAsyncThrowingReturnStub" : "_MocksmithAsyncReturnStub"
            let genericTypes = [argumentsType, ephemeralArgumentsType, outputType] + (isThrowing ? [failure] : []) + [answerType]
            let handle = "\(typeName)<\(genericTypes.joined(separator: ", "))>"
            let success = outputType == "Void"
                ? "\(registryResolution)\(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: [.returnValue(())])\n                "
                : ""
            return method(
                fluentSignature(arguments: matcherDeclarations, returning: handle, inferredFrom: handle),
                body: """
                \(success)return \(handle)(
                    member: "\(displayName)",
                    apply: { outcomes in
                        \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                    },
                    answer: \(answerAdapter)
                )
                """,
                attribute: outputType == "Void" ? "@discardableResult" : nil
            )
        }
        if outputType == "Void" {
            let successOutcome = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
            let success = "\(registryResolution)\(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: \(successOutcome))"
            guard isThrowing, !isRethrows else {
                return method(
                    fluentSignature(arguments: matcherDeclarations),
                    body: success
                )
            }
            let errorType = typedError ?? "any Error"
            let prefix = isTransient
                ? "_MocksmithThrowingProduceVoidStub"
                : "_MocksmithThrowingVoidStub"
            let handle = "\(prefix)<\(argumentsType), \(ephemeralArgumentsType), \(errorType), \(answerType)>"
            return method(
                fluentSignature(arguments: matcherDeclarations, returning: handle, inferredFrom: handle),
                body: """
                \(success)
                return \(handle)(
                    apply: { outcomes in
                        \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                    },
                    answer: \(answerAdapter)
                )
                """,
                attribute: "@discardableResult"
            )
        }
        let throwing = isThrowing && !isRethrows
        let typeName: String = if isTransient {
            throwing ? "_MocksmithThrowingProduceStub" : "_MocksmithProduceStub"
        } else {
            throwing ? "_MocksmithThrowingReturnStub" : "_MocksmithReturnStub"
        }
        let generics = [
            argumentsType,
            ephemeralArgumentsType,
            outputType,
            throwing ? (typedError ?? "any Error") : nil,
            answerType
        ].compactMap(\.self).joined(separator: ", ")
        let handle = "\(typeName)<\(generics)>"
        return method(
            fluentSignature(arguments: matcherDeclarations, returning: handle, inferredFrom: handle),
            body: """
            return \(handle)(
                apply: { outcomes in
                    \(registryResolution)return \(channelReference).addStub(matching: \(matcherClosure), specificity: \(specificity), outcomes: outcomes)
                },
                answer: \(answerAdapter)
            )
            """
        )
    }

    var verifyFactory: String {
        if isTransient {
            let labels = parameters.filter { $0.external != "_" }.map { "\($0.external): Void = ()" }.joined(separator: ", ")
            return method(
                fluentSignature(arguments: labels),
                body: "\(registryResolution)report(\(channelReference).verification(count: count))"
            )
        }
        return method(
            fluentSignature(arguments: matcherDeclarations),
            body: "\(registryResolution)report(\(channelReference).verification(matching: \(matcherClosure), count: count))"
        )
    }

    var callsFactory: String {
        guard !isTransient else {
            return ""
        }
        return method(
            fluentSignature(arguments: matcherDeclarations, returning: "CallHistory<\(argumentsType)>", inferredFrom: "CallHistory<\(argumentsType)>"),
            body: "\(registryResolution)return \(channelReference).callHistory(matching: \(matcherClosure))"
        )
    }

    var orderFactory: String {
        let labels = isTransient
            ? parameters.filter { $0.external != "_" }.map { "\($0.external): Void = ()" }.joined(separator: ", ")
            : matcherDeclarations
        let source = isStatic
            ? "sourceType: mock, invocations: { StaticMockRegistry.shared.orderedInvocations(owner: mock) }"
            : "source: mock, invocations: { mock._mocksmithOrderedInvocations }"
        let matches = isTransient
            ? "\(channelReference).matchesInvocation(sequence: sequence)"
            : "\(channelReference).matchesInvocation(sequence: sequence, matching: \(matcherClosure))"
        return method(
            fluentSignature(arguments: labels),
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
        let leading = matcherDeclarations.isEmpty ? "" : matcherDeclarations + ", "
        let outcomes: String = if outputType == "Void" {
            isTransient ? ", outcomes: [.producing { () }]" : ", outcomes: [.returnValue(())]"
        } else {
            ""
        }
        let body: String
        if hasEphemeralDispatcher {
            let recordableCall: String
            let ephemeralCalls = ephemeralParameters.map { ephemeralParameters.count == 1 ? "ephemeral" : "ephemeral.\($0.local)" }
            switch parameters.count {
                case 0: recordableCall = "action(" + ephemeralCalls.joined(separator: ", ") + ")"
                case 1: recordableCall = "action(" + (["arguments"] + ephemeralCalls).joined(separator: ", ") + ")"
                default: recordableCall = "action(" + (parameters.map { "arguments.\($0.local)" } + ephemeralCalls).joined(separator: ", ") + ")"
            }
            body = "\(registryResolution)\(channelReference).addAction(matching: \(matcherClosure), specificity: \(specificity)\(outcomes)) { arguments, ephemeral in \(recordableCall) }"
            let actionTypes = parameters.map(\.type) + ephemeralParameters.map(\.type)
            let actionType = "(" + actionTypes.joined(separator: ", ") + ") -> Void"
            return method(fluentSignature(arguments: "\(leading)_ action: @escaping \(actionType)"), body: body)
        }
        body = "\(registryResolution)\(channelReference).addAction(matching: \(matcherClosure), specificity: \(specificity)\(outcomes)) { arguments in \(actionCall) }"
        let actionLabel = parameters.contains(where: \.isPack) ? "perform action" : "_ action"
        return method(fluentSignature(arguments: "\(leading)\(actionLabel): @escaping \(actionType)"), body: body)
    }

    private func fluentSignature(
        arguments: String,
        returning returnType: String? = nil,
        inferredFrom: String = ""
    ) -> String {
        let genericParameters = (declaration.genericParameterClause?.parameters.map(\.name.text) ?? []) + opaqueParameters.map(\.name)
        var usedReturningLabel = false
        let tokens = genericParameters.compactMap { parameter -> String? in
            let inferenceSource = arguments + inferredFrom
            guard inferenceSource.range(of: "\\b\(NSRegularExpression.escapedPattern(for: parameter))\\b", options: .regularExpression) == nil else {
                return nil
            }
            let appearsInOutput = outputType.range(of: "\\b\(NSRegularExpression.escapedPattern(for: parameter))\\b", options: .regularExpression) != nil
            let label: String
            if appearsInOutput, !usedReturningLabel {
                label = "returning"
                usedReturningLabel = true
            } else {
                label = parameter.prefix(1).lowercased() + String(parameter.dropFirst()) + "Type"
            }
            return "\(label) _: \(parameter).Type"
        }
        let parameters = (tokens + (arguments.isEmpty ? [] : [arguments])).joined(separator: ", ")
        let result = returnType.map { " -> \($0)" } ?? ""
        return "\(factoryIsolation)func \(name)\(genericClause)(\(parameters))\(result)\(whereClause)"
    }

    private func method(_ signature: String, body: String, attribute: String? = nil) -> String {
        let body = matcherSetup + body
        let attributePrefix = attribute.map { "        \($0)\n" } ?? ""
        return availabilityPrefix(indentation: "        ")
            + attributePrefix
            + "        \(access)\(signature) {\n            \(body)\n        }"
    }

    private func availabilityPrefix(indentation: String) -> String {
        availability.isEmpty ? "" : availability.split(separator: "\n").map { indentation + $0 }.joined(separator: "\n") + "\n"
    }
}
