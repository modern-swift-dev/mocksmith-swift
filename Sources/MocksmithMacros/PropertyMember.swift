import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Models generated channels, accessors, and factories for a property requirement.
struct PropertyMember {
    enum Kind { case get, set }
    let name: String
    let type: String
    let kind: Kind
    let index: Int
    let access: String
    let isReadWrite: Bool
    let isStatic: Bool
    let nonisolatedModifier: String
    let factoryIsolation: String
    let getterHeader: String
    let availability: String
    let witnessAttributes: String
    let isTransient: Bool
    let isOptionalResult: Bool
    let isVoidResult: Bool
    var usesRegistry: Bool {
        !availability.isEmpty
    }

    static func isSupported(_ declaration: VariableDeclSyntax) -> Bool {
        guard declaration.bindings.count == 1, let binding = declaration.bindings.first,
              binding.pattern.is(IdentifierPatternSyntax.self), binding.typeAnnotation != nil else {
            return false
        }
        return true
    }

    static func make(_ declaration: VariableDeclSyntax, index: Int, access: String, replacements: [String: String], mockType: String, factoryIsolation: String) -> [Self] {
        guard isSupported(declaration), let binding = declaration.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation else {
            return []
        }
        let text = binding.accessorBlock?.trimmedDescription ?? "{ get }"
        let settable = text.contains("set")
        let isStatic = declaration.modifiers.contains { ["static", "class"].contains($0.name.text) }
        let nonisolatedModifier = declaration.modifiers.first(where: { $0.name.text == "nonisolated" })?.trimmedDescription ?? ""
        let type = rewriteType(annotation.type, replacements: replacements, mockType: mockType)
        let accessors: [AccessorDeclSyntax] = {
            guard let block = binding.accessorBlock, case let .accessors(list) = block.accessors else {
                return []
            }
            return Array(list)
        }()
        let getterHeader = accessors.first(where: { $0.accessorSpecifier.text == "get" }).map(accessorHeader) ?? "get"
        let availability = availabilityAttributes(declaration.attributes)
        let witnessAttributes = witnessAttributePrefix(declaration.attributes, indentation: "    ")
        let isTransient = hasAttribute(named: "MockNoncopyable", in: declaration.attributes) || declaration.trimmedDescription.contains("~Copyable")
        let isOptionalResult = isOptionalType(annotation.type)
        let isVoidResult = isVoidType(annotation.type)
        var result = [Self(
            name: pattern.identifier.text,
            type: type,
            kind: .get,
            index: index,
            access: access,
            isReadWrite: settable,
            isStatic: isStatic,
            nonisolatedModifier: nonisolatedModifier,
            factoryIsolation: factoryIsolation,
            getterHeader: getterHeader,
            availability: availability,
            witnessAttributes: witnessAttributes,
            isTransient: isTransient,
            isOptionalResult: isOptionalResult,
            isVoidResult: isVoidResult
        )]
        if settable {
            result.append(Self(
                name: pattern.identifier.text,
                type: type,
                kind: .set,
                index: index,
                access: access,
                isReadWrite: true,
                isStatic: isStatic,
                nonisolatedModifier: nonisolatedModifier,
                factoryIsolation: factoryIsolation,
                getterHeader: getterHeader,
                availability: availability,
                witnessAttributes: witnessAttributes,
                isTransient: isTransient,
                isOptionalResult: isOptionalResult,
                isVoidResult: isVoidResult
            ))
        }
        return result
    }

    var suffix: String {
        kind == .get ? "get" : "set"
    }

    var channelName: String {
        "_mock_\(name)_\(suffix)_\(index)"
    }

    var displayName: String {
        "\(name).\(suffix)"
    }

    var argumentsType: String {
        kind == .get ? "Void" : type
    }

    var outputType: String {
        kind == .get ? type : "Void"
    }

    var defaultFallback: String? {
        guard !isStatic, !isThrowing else {
            return nil
        }
        let policy = isAsync ? "_mocksmithDefaultPolicy" : "self._mocksmithDefaultPolicy"
        if kind == .set || isVoidResult {
            return "{ switch \(policy) { case .void, .voidAndOptional: (); case .strict: preconditionFailure(\"Unstubbed nonthrowing member \(displayName)\") } }"
        }
        if isOptionalResult {
            return "{ switch \(policy) { case .voidAndOptional: nil; case .strict, .void: preconditionFailure(\"Unstubbed nonthrowing member \(displayName)\") } }"
        }
        return nil
    }

    var getterEffects: String {
        getterHeader.replacingOccurrences(of: "get", with: "", options: [.anchored]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAsync: Bool {
        getterEffects.range(of: #"\basync\b"#, options: .regularExpression) != nil
    }

    var isThrowing: Bool {
        getterEffects.range(of: #"\bthrows\b"#, options: .regularExpression) != nil
    }

    var typedError: String? {
        parsedTypedError(getterEffects)
    }

    var answerType: String {
        let effects = (isAsync ? " async" : "") + (isThrowing ? " throws" : "")
        return "()\(effects) -> \(type)"
    }

    var answerAdapter: String {
        let prefix = (isThrowing ? "try " : "") + (isAsync ? "await " : "")
        let runtimeParameters = isAsync ? "arguments" : "arguments, _"
        return "{ answer in .answering { \(runtimeParameters) in \(prefix)answer() } }"
    }

    var channelType: String {
        "\(isTransient ? "TransientMockMember" : "MockMember")<\(argumentsType), Void, \(outputType)>"
    }

    var channelConstructor: String {
        "\(channelType)(name: \"\(displayName)\")"
    }

    var registryResolution: String {
        guard usesRegistry else {
            return ""
        }
        if isStatic {
            return "let member: \(channelType) = StaticMockRegistry.shared.member(owner: mock, key: \"\(channelName)\", types: []) { \(channelConstructor) }\n            "
        }
        return "let member: \(channelType) = mock._genericMockRegistry.member(key: \"\(channelName)\", types: []) { \(channelConstructor) }\n            "
    }

    var witnessRegistryResolution: String {
        guard usesRegistry else {
            return ""
        }
        if isStatic {
            return "let member: \(channelType) = StaticMockRegistry.shared.member(owner: Self.self, key: \"\(channelName)\", types: []) { \(channelConstructor) }\n            "
        }
        return "let member: \(channelType) = _genericMockRegistry.member(key: \"\(channelName)\", types: []) { \(channelConstructor) }\n            "
    }

    var channelReference: String {
        usesRegistry ? "member" : "mock.\(channelName)"
    }

    var witnessChannelReference: String {
        usesRegistry ? "member" : channelName
    }

    var witness: String {
        guard kind == .get else {
            return ""
        }
        let fallback = defaultFallback.map { ", unstubbed: \($0)" } ?? ""
        let defaultPolicySnapshot = isAsync && defaultFallback != nil
            ? "let _mocksmithDefaultPolicy = self._mocksmithDefaultPolicy\n            "
            : ""
        let call = "try \(isAsync ? "await " : "")\(witnessChannelReference).\(isAsync ? "invokeAsync" : "invoke")(\(kind == .get ? "()" : "newValue")\(fallback))"
        let getterBody = if let typedError {
            "\(witnessRegistryResolution)do { return \(call) }\n            catch let error as \(typedError) { throw error }\n            catch { preconditionFailure(\"Invalid or unstubbed typed-throws member \(name).get: \\(error)\") }"
        } else if isThrowing {
            "\(witnessRegistryResolution)return \(call)"
        } else {
            "\(witnessRegistryResolution)\(defaultPolicySnapshot)do { return \(call) }\n            catch { preconditionFailure(\"Unstubbed nonthrowing member \(name).get: \\(error)\") }"
        }
        let getter = "\(getterHeader) {\n            \(getterBody)\n        }"
        let setterChannel = usesRegistry ? "member" : "_mock_\(name)_set_\(index)"
        let setterResolution: String
        if usesRegistry {
            let setterType = "\(isTransient ? "TransientMockMember" : "MockMember")<\(type), Void, Void>"
            if isStatic {
                setterResolution =
                    "let member: \(setterType) = StaticMockRegistry.shared.member(owner: Self.self, key: \"_mock_\(name)_set_\(index)\", types: []) { \(setterType)(name: \"\(name).set\") }\n            "
            } else {
                setterResolution = "let member: \(setterType) = _genericMockRegistry.member(key: \"_mock_\(name)_set_\(index)\", types: []) { \(setterType)(name: \"\(name).set\") }\n            "
            }
        } else {
            setterResolution = ""
        }
        let setterFallback = !isStatic ?
            ", unstubbed: { switch self._mocksmithDefaultPolicy { case .void, .voidAndOptional: (); case .strict: preconditionFailure(\"Unstubbed nonthrowing member \(name).set\") } }" : ""
        let setter = isReadWrite ?
            "\n        set {\n            \(setterResolution)do { return try \(setterChannel).invoke(newValue\(setterFallback)) }\n            catch { preconditionFailure(\"Unstubbed nonthrowing member \(name).set: \\(error)\") }\n        }" :
            ""
        let prefix = availability.isEmpty ? "" : availability + "\n"
        return prefix + witnessAttributes + "    \(access)\(nonisolatedModifier.isEmpty ? "" : nonisolatedModifier + " ")\(isStatic ? "static " : "")var \(name): \(type) {\n        \(getter)\(setter)\n    }"
    }

    var givenFactory: String {
        switch kind {
            case .get:
                if isAsync, !isTransient {
                    let failure = isThrowing ? (typedError ?? "any Error") : "Never"
                    let typeName = isThrowing ? "_MocksmithAsyncThrowingReturnStub" : "_MocksmithAsyncReturnStub"
                    let genericTypes = ["Void", "Void", type] + (isThrowing ? [failure] : []) + [answerType]
                    let handle = "\(typeName)<\(genericTypes.joined(separator: ", "))>"
                    let success = type == "Void"
                        ? "\(registryResolution)\(channelReference).addStub(matching: { _ in true }, specificity: 0, outcomes: [.returnValue(())])\n                        "
                        : ""
                    return declaration(
                        "var \(name): \(handle)",
                        body: """
                        \(success)return \(handle)(
                            member: "\(displayName)",
                            apply: { outcomes in
                                \(registryResolution)return \(channelReference).addStub(matching: { _ in true }, specificity: 0, outcomes: outcomes)
                            },
                            answer: \(answerAdapter)
                        )
                        """
                    )
                }
                if type == "Void" {
                    let successOutcome = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
                    let success = "\(registryResolution)\(channelReference).addStub(matching: { _ in true }, specificity: 0, outcomes: \(successOutcome))"
                    guard isThrowing else {
                        return declaration("var \(name): Void", body: success)
                    }
                    let errorType = typedError ?? "any Error"
                    let prefix = isTransient
                        ? "_MocksmithThrowingProduceVoidStub"
                        : "_MocksmithThrowingVoidStub"
                    let handle = "\(prefix)<Void, Void, \(errorType), \(answerType)>"
                    return declaration(
                        "var \(name): \(handle)",
                        body: """
                        \(success)
                        return \(handle)(
                            apply: { outcomes in
                                \(registryResolution)return \(channelReference).addStub(matching: { _ in true }, specificity: 0, outcomes: outcomes)
                            },
                            answer: \(answerAdapter)
                        )
                        """
                    )
                }
                let typeName: String = if isTransient {
                    isThrowing ? "_MocksmithThrowingProduceStub" : "_MocksmithProduceStub"
                } else {
                    isThrowing ? "_MocksmithThrowingReturnStub" : "_MocksmithReturnStub"
                }
                let genericTypes = ["Void", "Void", type] + (isThrowing ? [typedError ?? "any Error"] : []) + [answerType]
                let handle = "\(typeName)<\(genericTypes.joined(separator: ", "))>"
                return declaration(
                    "var \(name): \(handle)",
                    body: """
                    return \(handle)(
                        apply: { outcomes in
                            \(registryResolution)return \(channelReference).addStub(matching: { _ in true }, specificity: 0, outcomes: outcomes)
                        },
                        answer: \(answerAdapter)
                    )
                    """
                )
            case .set:
                let outcomes = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
                return declaration(
                    "func \(name)(set matching: Parameter<\(type)>)",
                    body: "\(registryResolution)\(channelReference).addStub(matching: { matching.matches($0) }, specificity: matching.specificity, outcomes: \(outcomes))"
                )
        }
    }

    var verifyFactory: String {
        switch kind {
            case .get:
                let verification = isTransient
                    ? "\(channelReference).verification(count: count)"
                    : "\(channelReference).verification(matching: { _ in true }, count: count)"
                return declaration("func \(name)()", body: "\(registryResolution)report(\(verification))")
            case .set:
                let signature = isTransient
                    ? "func \(name)(set: Void = ())"
                    : "func \(name)(set matching: Parameter<\(type)>)"
                let verification = isTransient
                    ? "\(channelReference).verification(count: count)"
                    : "\(channelReference).verification(matching: { matching.matches($0) }, count: count)"
                return declaration(signature, body: "\(registryResolution)report(\(verification))")
        }
    }

    var callsFactory: String {
        guard !isTransient else {
            return ""
        }
        switch kind {
            case .get:
                return declaration(
                    "func \(name)() -> CallHistory<Void>",
                    body: "\(registryResolution)return \(channelReference).callHistory(matching: { _ in true })"
                )
            case .set:
                return declaration(
                    "func \(name)(set matching: Parameter<\(type)>) -> CallHistory<\(type)>",
                    body: "\(registryResolution)return \(channelReference).callHistory(matching: { matching.matches($0) })"
                )
        }
    }

    var stateFactory: String {
        guard kind == .get, !isTransient else {
            return ""
        }

        let failure = isThrowing ? (typedError ?? "any Error") : "Never"
        let initialType = isThrowing ? "Result<\(type), \(failure)>" : type
        let controllerType = "MockPropertyState<\(type), \(failure)>"
        let valueExpression = isThrowing ? "try state.get()" : "state.value"
        let outcome = isAsync
            ? ".asyncAnswer { _ in \(valueExpression) }"
            : ".answer { _, _ in \(valueExpression) }"
        let controller = "let state = \(controllerType)(initial: initial)"

        let getterRegistration = """
        do {
                \(registryResolution)\(channelReference).addStub(
                    matching: { _ in true },
                    specificity: 0,
                    outcomes: [\(outcome)]
                )
            }
        """

        let setterRegistration: String
        if isReadWrite {
            let setterName = "_mock_\(name)_set_\(index)"
            let setterType = "MockMember<\(type), Void, Void>"
            let resolution: String
            let reference: String
            if usesRegistry {
                if isStatic {
                    resolution = "let member: \(setterType) = StaticMockRegistry.shared.member(owner: mock, key: \"\(setterName)\", types: []) { \(setterType)(name: \"\(name).set\") }\n                "
                } else {
                    resolution = "let member: \(setterType) = mock._genericMockRegistry.member(key: \"\(setterName)\", types: []) { \(setterType)(name: \"\(name).set\") }\n                "
                }
                reference = "member"
            } else {
                resolution = ""
                reference = "mock.\(setterName)"
            }
            setterRegistration = """

            do {
                \(resolution)\(reference).addAction(
                    matching: { _ in true },
                    specificity: 0,
                    outcomes: [.returnValue(())],
                    action: { state.succeed(with: $0) }
                )
            }
            """
        } else {
            setterRegistration = ""
        }

        return declaration(
            "func \(name)(initial: \(initialType)) -> \(controllerType)",
            body: """
            \(controller)
            \(getterRegistration)\(setterRegistration)
            return state
            """
        )
    }

    var orderFactory: String {
        let signature: String
        let matches: String
        switch kind {
            case .get:
                signature = "func \(name)()"
                matches = isTransient
                    ? "\(channelReference).matchesInvocation(sequence: sequence)"
                    : "\(channelReference).matchesInvocation(sequence: sequence, matching: { _ in true })"
            case .set:
                signature = isTransient
                    ? "func \(name)(set: Void = ())"
                    : "func \(name)(set matching: Parameter<\(type)>)"
                matches = isTransient
                    ? "\(channelReference).matchesInvocation(sequence: sequence)"
                    : "\(channelReference).matchesInvocation(sequence: sequence, matching: { matching.matches($0) })"
        }
        let source = isStatic
            ? "sourceType: mock, invocations: { StaticMockRegistry.shared.orderedInvocations(owner: mock) }"
            : "source: mock, invocations: { mock._mocksmithOrderedInvocations }"
        return declaration(
            signature,
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
        switch kind {
            case .get:
                return declaration(
                    "func \(name)(_ action: @escaping () -> Void)",
                    body: "\(registryResolution)\(channelReference).addAction(matching: { _ in true }, specificity: 0) { _ in action() }"
                )
            case .set:
                let ownership = isTransient ? "borrowing " : ""
                let outcomes = isTransient ? "[.producing { () }]" : "[.returnValue(())]"
                return declaration(
                    "func \(name)(set matching: Parameter<\(type)>, _ action: @escaping (\(ownership)\(type)) -> Void)",
                    body: "\(registryResolution)\(channelReference).addAction(matching: { matching.matches($0) }, specificity: matching.specificity, outcomes: \(outcomes), action: action)"
                )
        }
    }

    private func declaration(_ signature: String, body: String) -> String {
        (availability.isEmpty ? "" : availability.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n")
            + "        \(access)\(factoryIsolation)\(signature) {\n            \(body)\n        }"
    }
}
