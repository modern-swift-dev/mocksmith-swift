import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Generates a mock from a protocol surface resolved by the build plugin.
public struct ResolvedMockableMacro: PeerMacro {
    /// MockGenerator already formats its source; avoid walking the entire expansion again.
    public static var formatMode: FormatMode {
        .disabled
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let protocolDecl = declaration.as(ProtocolDeclSyntax.self),
              case let .argumentList(arguments) = node.arguments,
              let type = arguments.first?.expression.as(MemberAccessExprSyntax.self),
              type.declName.baseName.text == "self",
              let conformance = type.base?.trimmedDescription,
              let accessArgument = arguments.first(where: { $0.label?.text == "access" }),
              let accessExpression = accessArgument.expression.as(MemberAccessExprSyntax.self) else {
            diagnose("@_MocksmithResolved received invalid generated input", at: declaration, in: context)
            return []
        }

        let access: String
        switch accessExpression.declName.baseName.text {
            case "public": access = "public "
            case "package": access = "package "
            case "internal": access = ""
            default:
                diagnose("@_MocksmithResolved received invalid access", at: accessExpression, in: context)
                return []
        }

        let inherited = protocolDecl.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        } ?? []
        let mockType = conformance.split(separator: ".").last.map(String.init) ?? conformance
        let generator = MockGenerator(
            protocolDecl: protocolDecl,
            isActor: inherited.contains("Actor"),
            mockType: mockType + "Mock",
            conformanceType: conformance,
            access: access
        )
        guard generator.validate(in: context) else {
            return []
        }
        return [DeclSyntax(stringLiteral: generator.render())]
    }
}
