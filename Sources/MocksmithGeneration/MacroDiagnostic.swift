import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Reports validation failures produced by Mocksmith macros.
private struct MacroDiagnostic: DiagnosticMessage {
    let message: String
    let severity: DiagnosticSeverity
    var diagnosticID: MessageID {
        MessageID(domain: "Mocksmith.Mockable", id: message)
    }
}

package func diagnose(
    _ message: String,
    at node: some SyntaxProtocol,
    in context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: Syntax(node), message: MacroDiagnostic(message: message, severity: .error)))
}

func diagnoseWarning(
    _ message: String,
    at node: some SyntaxProtocol,
    in context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: Syntax(node), message: MacroDiagnostic(message: message, severity: .warning)))
}
