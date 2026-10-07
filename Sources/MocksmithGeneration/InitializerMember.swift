import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Models generated recording and verification for an initializer requirement.
///
/// Every value derived from the declaration is computed once in `init`; the
/// witnesses and factories below read them many times while rendering.
struct InitializerMember {
    let declaration: InitializerDeclSyntax
    let index: Int
    let access: String
    let replacements: [String: String]
    let mockType: String
    let factoryIsolation: String
    let isActor: Bool
    let isObjectiveC: Bool

    let parameters: [ParameterInfo]
    let opaqueParameters: [(name: String, constraint: String)]
    let isGeneric: Bool
    let isTransient: Bool
    let argumentsType: String
    let channelType: String
    let availability: String
    let usesRegistry: Bool
    let genericTypes: String
    let packGenericNames: [String]
    let genericClause: String
    let whereClause: String
    let channelName: String
    let displayName: String
    let matcherDeclarations: String
    let witnessCollisionKey: String
    let defaultsCollisionKey: String
    let configurationCollisionKey: String
    /// Type-pinning parameters for transient factories, which take no matchers.
    private let transientTypeTokens: String

    init(
        declaration: InitializerDeclSyntax,
        index: Int,
        access: String,
        replacements: [String: String],
        mockType: String,
        factoryIsolation: String,
        isActor: Bool,
        isObjectiveC: Bool
    ) {
        self.declaration = declaration
        self.index = index
        self.access = access
        self.replacements = replacements
        self.mockType = mockType
        self.factoryIsolation = factoryIsolation
        self.isActor = isActor
        self.isObjectiveC = isObjectiveC

        let declaredParameters = Array(declaration.signature.parameterClause.parameters)
        var opaqueNamesByPosition: [Int: String] = [:]
        opaqueParameters = declaredParameters.enumerated().compactMap { position, parameter in
            let opaque = opaqueParameterType(parameter.type.trimmedDescription, position: position)
            opaqueNamesByPosition[position] = opaque?.name
            return opaque
        }
        let rewrittenTypes = declaredParameters.map { rewriteType($0.type, replacements: replacements, mockType: mockType) }
        let parameters = declaredParameters.enumerated().map { position, parameter in
            let external = parameter.firstName.text
            let local = parameter.secondName?.text ?? (external == "_" ? "argument\(position)" : external)
            var type = opaqueNamesByPosition[position] ?? rewrittenTypes[position]
            if parameter.ellipsis != nil {
                type = "[\(type)]"
            }
            for prefix in ["inout ", "borrowing ", "consuming ", "sending "] where type.hasPrefix(prefix) {
                type.removeFirst(prefix.count)
            }
            return ParameterInfo(external: external, local: local, type: type, matcher: "matching\(position)", position: position)
        }
        self.parameters = parameters
        matcherDeclarations = parameters.map(\.declaration).joined(separator: ", ")
        channelName = "_mock_initializer_\(index)"
        displayName = "init" + declaredParameters.map { "\($0.firstName.text):" }.joined()

        isTransient = isTransientRequirement(declaration)
        if isTransient {
            argumentsType = "Void"
        } else if parameters.count == 1, parameters[0].isPack {
            argumentsType = "(\(parameters[0].type))"
        } else {
            argumentsType = switch parameters.count {
                case 0: "Void"
                case 1: parameters[0].type
                default: "(" + parameters.map { "\($0.local): \($0.type)" }.joined(separator: ", ") + ")"
            }
        }
        channelType = "\(isTransient ? "TransientMockMember" : "MockMember")<\(argumentsType), Void, Void>"

        isGeneric = declaration.genericParameterClause != nil || !opaqueParameters.isEmpty
        availability = availabilityAttributes(declaration.attributes)
        usesRegistry = isGeneric || !availability.isEmpty

        let genericParameters = declaration.genericParameterClause?.parameters
        genericTypes = ((genericParameters?.filter { $0.specifier == nil }.map { "\($0.name.text).self" } ?? [])
            + opaqueParameters.map { "\($0.name).self" }).joined(separator: ", ")
        packGenericNames = genericParameters?.compactMap { $0.specifier == nil ? nil : $0.name.text } ?? []
        let allGenerics = (genericParameters?.map(\.trimmedDescription) ?? []) + opaqueParameters.map { "\($0.name): \($0.constraint)" }
        genericClause = allGenerics.isEmpty ? "" : "<\(allGenerics.joined(separator: ", "))>"
        let rewrittenWhereClause = declaration.genericWhereClause.map { rewriteType($0, replacements: replacements, mockType: mockType) }
        whereClause = rewrittenWhereClause.map { " " + $0 } ?? ""

        let explicitTypeTokens = genericParameters?.map { parameter -> String in
            if parameter.specifier != nil {
                return "_ types: repeat (each \(parameter.name.text)).Type"
            }
            let label = parameter.name.text.prefix(1).lowercased() + String(parameter.name.text.dropFirst()) + "Type"
            return "\(label) _: \(parameter.name.text).Type"
        } ?? []
        let opaqueTypeTokens = parameters.indices.compactMap { position in
            opaqueNamesByPosition[position].map { "\(parameters[position].local)Type _: \($0).Type" }
        }
        transientTypeTokens = (explicitTypeTokens + opaqueTypeTokens).joined(separator: ", ")

        // Collision keys canonicalize generic parameter names so that initializers
        // differing only in those names still collide.
        let genericNames = genericParameters?.enumerated().map { ($0.element.name.text, "_Generic\($0.offset)") } ?? []
        let canonicalize: (String) -> String = { source in
            genericNames.reduce(source) { result, replacement in
                result.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: replacement.0))\\b",
                    with: replacement.1,
                    options: .regularExpression
                )
            }
        }
        let parameterKeys = declaredParameters.enumerated().map { position, parameter in
            "\(parameter.firstName.text):\(canonicalize(rewrittenTypes[position]))\(parameter.ellipsis?.text ?? "")"
        }
        let keyPrefix = canonicalize(declaration.genericParameterClause.map { rewriteType($0, replacements: replacements, mockType: mockType) } ?? "")
        let keySuffix = canonicalize(rewrittenWhereClause ?? "")
        let collisionKey: ([String]) -> String = { appending in
            keyPrefix + "(" + (parameterKeys + appending).joined(separator: ",") + ")" + keySuffix
        }
        witnessCollisionKey = collisionKey([])
        defaultsCollisionKey = collisionKey(["defaults:MockDefaultPolicy"])
        configurationCollisionKey = collisionKey(["defaults:MockDefaultPolicy", "configure:(\(mockType))->Void"])
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
        return "\(registrySetup)let member: \(channelType) = mock._genericMockRegistry.member(key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelType)(name: \"\(displayName)\") }\n            "
    }

    var witnessRegistryResolution: String {
        guard usesRegistry else {
            return ""
        }
        return "\(registrySetup.replacingOccurrences(of: "            ", with: "        "))let member: \(channelType) = _genericMockRegistry.member(key: \"\(channelName)\", typeIDs: \(registryTypes)) { \(channelType)(name: \"\(displayName)\") }\n        "
    }

    var channelReference: String {
        usesRegistry ? "member" : "mock.\(channelName)"
    }

    var argumentsExpression: String {
        if parameters.count == 1, parameters[0].isPack {
            return "(repeat each \(parameters[0].local))"
        }
        return switch parameters.count {
            case 0: "()"
            case 1: parameters[0].local
            default: "(" + parameters.map { "\($0.local): \($0.local)" }.joined(separator: ", ") + ")"
        }
    }

    var matcherClosure: String {
        guard !parameters.isEmpty else {
            return "{ _ in true }"
        }
        if parameters.count == 1, let parameter = parameters.first, parameter.isPack {
            return "{ arguments in var result = true; for (argument, matcher) in repeat (each arguments, each \(parameter.matcher)) { result = result && matcher.matches(argument) }; return result }"
        }
        return "{ arguments in " + parameters.map { parameter in
            let value = parameters.count == 1 ? "arguments" : "arguments.\(parameter.local)"
            return "\(parameter.matcher).matches(\(value))"
        }.joined(separator: " && ") + " }"
    }

    var witness: String {
        let required = isActor ? "" : "required "
        let override = isObjectiveC && parameters.isEmpty && declaration.optionalMark == nil
            && declaration.signature.effectSpecifiers == nil ? "override " : ""
        var signature = rewriteType(declaration.signature, replacements: replacements, mockType: mockType)
        for opaque in opaqueParameters {
            signature.replaceFirst("some \(opaque.constraint)", with: opaque.name)
        }
        let attributes = declaration.attributes.map(\.trimmedDescription).joined(separator: "\n    ")
        let attributePrefix = attributes.isEmpty ? "" : "    " + attributes + "\n"
        let ignored = Set(["required", "public", "package", "internal", "fileprivate", "private"])
        let modifiers = declaration.modifiers.map(\.name.text).filter { !ignored.contains($0) }.joined(separator: " ")
        let modifierPrefix = modifiers.isEmpty ? "" : modifiers + " "
        let recording = isTransient ? "\(usesRegistry ? "member" : channelName).record()" : "\(usesRegistry ? "member" : channelName).record(\(argumentsExpression))"
        return "\(attributePrefix)    \(access)\(required)\(override)\(modifierPrefix)init\(declaration.optionalMark?.text ?? "")\(genericClause)\(signature)\(whereClause) {\n        _mocksmithDefaultPolicy = .strict\n        \(witnessRegistryResolution)\(recording)\n    }"
    }

    var defaultsWitness: String {
        guard !declaration.signature.parameterClause.parameters.contains(where: { $0.firstName.text == "defaults" }) else {
            return ""
        }
        var parameterClause = rewriteType(declaration.signature.parameterClause, replacements: replacements, mockType: mockType)
        for opaque in opaqueParameters {
            parameterClause.replaceFirst("some \(opaque.constraint)", with: opaque.name)
        }
        parameterClause.insert(
            contentsOf: parameterClause == "()" ? "defaults _mocksmithDefaults: MockDefaultPolicy" : ", defaults _mocksmithDefaults: MockDefaultPolicy",
            at: parameterClause.index(before: parameterClause.endIndex)
        )
        let effects = declaration.signature.effectSpecifiers.map { " " + $0.trimmedDescription } ?? ""
        let attributes = declaration.attributes.compactMap { attribute -> String? in
            guard let attribute = attribute.as(AttributeSyntax.self) else {
                return nil
            }
            let name = attribute.attributeName.trimmedDescription.split(separator: ".").last
            return name == "objc" ? nil : attribute.trimmedDescription
        }.joined(separator: "\n    ")
        let attributePrefix = attributes.isEmpty ? "" : "    " + attributes + "\n"
        let ignored = Set(["required", "public", "package", "internal", "fileprivate", "private"])
        let modifiers = declaration.modifiers.map(\.name.text).filter { !ignored.contains($0) && $0 != "optional" }.joined(separator: " ")
        let modifierPrefix = modifiers.isEmpty ? "" : modifiers + " "
        let recording = isTransient ? "\(usesRegistry ? "member" : channelName).record()" : "\(usesRegistry ? "member" : channelName).record(\(argumentsExpression))"
        return "\(attributePrefix)    \(access)\(modifierPrefix)init\(declaration.optionalMark?.text ?? "")\(genericClause)\(parameterClause)\(effects)\(whereClause) {\n        _mocksmithDefaultPolicy = _mocksmithDefaults\n        \(witnessRegistryResolution)\(recording)\n    }"
    }

    var configurationWitness: String {
        guard !declaration.signature.parameterClause.parameters.contains(where: { ["defaults", "configure"].contains($0.firstName.text) }) else {
            return ""
        }
        var parameterClause = rewriteType(declaration.signature.parameterClause, replacements: replacements, mockType: mockType)
        for opaque in opaqueParameters {
            parameterClause.replaceFirst("some \(opaque.constraint)", with: opaque.name)
        }
        let appended = "defaults _mocksmithDefaults: MockDefaultPolicy = .strict, configure _mocksmithConfigure: (\(mockType)) -> Void"
        parameterClause.insert(
            contentsOf: parameterClause == "()" ? appended : ", " + appended,
            at: parameterClause.index(before: parameterClause.endIndex)
        )
        let effects = declaration.signature.effectSpecifiers.map { " " + $0.trimmedDescription } ?? ""
        let attributes = declaration.attributes.compactMap { attribute -> String? in
            guard let attribute = attribute.as(AttributeSyntax.self) else {
                return nil
            }
            let name = attribute.attributeName.trimmedDescription.split(separator: ".").last
            return name == "objc" ? nil : attribute.trimmedDescription
        }.joined(separator: "\n    ")
        let attributePrefix = attributes.isEmpty ? "" : "    " + attributes + "\n"
        let ignored = Set(["required", "public", "package", "internal", "fileprivate", "private", "optional"])
        let modifiers = declaration.modifiers.map(\.name.text).filter { !ignored.contains($0) }.joined(separator: " ")
        let modifierPrefix = modifiers.isEmpty ? "" : modifiers + " "
        let recording = isTransient ? "\(usesRegistry ? "member" : channelName).record()" : "\(usesRegistry ? "member" : channelName).record(\(argumentsExpression))"
        return "\(attributePrefix)    \(access)\(modifierPrefix)init\(declaration.optionalMark?.text ?? "")\(genericClause)\(parameterClause)\(effects)\(whereClause) {\n        _mocksmithDefaultPolicy = _mocksmithDefaults\n        \(witnessRegistryResolution)\(recording)\n        _mocksmithConfigure(self)\n    }"
    }

    var verifyFactory: String {
        let availabilityPrefix = availability.isEmpty ? "" : availability.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n"
        if isTransient {
            return availabilityPrefix + """
                    \(access)\(factoryIsolation)func initializer\(genericClause)(\(transientTypeTokens))\(whereClause) {
                        \(registryResolution)report(\(channelReference).verification(count: count))
                    }
            """
        }
        return availabilityPrefix + """
                \(access)\(factoryIsolation)func initializer\(genericClause)(\(matcherDeclarations))\(whereClause) {
                    \(registryResolution)report(\(channelReference).verification(matching: \(matcherClosure), count: count))
                }
        """
    }

    var callsFactory: String {
        guard !isTransient else {
            return ""
        }
        let availabilityPrefix = availability.isEmpty ? "" : availability.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n"
        return availabilityPrefix + """
                \(access)\(factoryIsolation)func initializer\(genericClause)(\(matcherDeclarations)) -> CallHistory<\(argumentsType)>\(whereClause) {
                    \(registryResolution)return \(channelReference).callHistory(matching: \(matcherClosure))
                }
        """
    }

    var orderFactory: String {
        let availabilityPrefix = availability.isEmpty ? "" : availability.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n"
        if isTransient {
            return availabilityPrefix + """
                    \(access)\(factoryIsolation)func initializer\(genericClause)(\(transientTypeTokens))\(whereClause) {
                        \(registryResolution)order._append(
                            source: mock,
                            invocations: { mock._mocksmithOrderedInvocations },
                            member: "\(displayName)",
                            matches: { sequence in \(channelReference).matchesInvocation(sequence: sequence) },
                            markVerified: { sequence in \(channelReference)._mocksmithMarkVerified(sequence: sequence) }
                        )
                    }
            """
        }
        return availabilityPrefix + """
                \(access)\(factoryIsolation)func initializer\(genericClause)(\(matcherDeclarations))\(whereClause) {
                    \(registryResolution)order._append(
                        source: mock,
                        invocations: { mock._mocksmithOrderedInvocations },
                        member: "\(displayName)",
                        matches: { sequence in \(channelReference).matchesInvocation(sequence: sequence, matching: \(matcherClosure)) },
                        markVerified: { sequence in \(channelReference)._mocksmithMarkVerified(sequence: sequence) }
                    )
                }
        """
    }
}
