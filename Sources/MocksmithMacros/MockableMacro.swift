import Foundation
import MocksmithGeneration
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Generates a concrete mock peer for an annotated protocol.
public struct MockableMacro: PeerMacro {
    /// MockGenerator already formats its source; avoid walking the entire expansion again.
    public static var formatMode: FormatMode {
        .disabled
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let protocolDecl = declaration.as(ProtocolDeclSyntax.self) else {
            diagnose("@Mockable can only be attached to a protocol", at: declaration, in: context)
            return []
        }

        guard let mode = MockGenerationMode(node) else {
            diagnose("@Mockable generation must be .macro or .buildPlugin", at: node, in: context)
            return []
        }
        if mode == .buildPlugin {
            if !context.lexicalContext.isEmpty || protocolDecl.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
            }) {
                diagnose(
                    "@Mockable(.buildPlugin) requires an internal, package, or public top-level protocol",
                    at: protocolDecl,
                    in: context
                )
            }
            return []
        }

        let inherited = protocolDecl.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        } ?? []
        let markers = Set(["AnyObject", "Sendable", "Actor", "~Copyable", "NSObjectProtocol"])
        if inherited.contains(where: { !markers.contains($0) }) {
            return []
        }

        let generator = MockGenerator(protocolDecl: protocolDecl, isActor: inherited.contains("Actor"))
        guard generator.validate(in: context) else {
            return []
        }
        return [DeclSyntax(stringLiteral: generator.render())]
    }
}
