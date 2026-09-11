import SwiftSyntax

/// Reads the literal generation mode consistently in the macro and build tool.
package enum MockGenerationMode {
    case macro
    case buildPlugin

    package init?(_ attribute: AttributeSyntax) {
        guard case let .argumentList(arguments) = attribute.arguments,
              let argument = arguments.first else {
            self = .buildPlugin
            return
        }
        guard let member = argument.expression.as(MemberAccessExprSyntax.self) else {
            return nil
        }
        switch member.declName.baseName.text {
            case "macro": self = .macro
            case "buildPlugin": self = .buildPlugin
            default: return nil
        }
    }
}
