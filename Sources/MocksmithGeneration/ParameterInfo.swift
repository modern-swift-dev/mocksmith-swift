import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Describes a generated member parameter and its matcher.
struct ParameterInfo {
    let external: String
    let local: String
    let type: String
    let matcher: String
    let position: Int

    var isPack: Bool {
        type.hasPrefix("repeat each ")
    }

    var packElement: String {
        isPack ? String(type.dropFirst("repeat ".count)) : type
    }

    var declaration: String {
        "\(external == "_" ? "_" : external) \(matcher): \(isPack ? "repeat Parameter<\(packElement)>" : "Parameter<\(type)>")"
    }

    var actionDeclaration: String {
        "\(external == "_" ? "_" : external) \(local): \(type)"
    }

    var argumentAccess: String {
        position == 0 ? "arguments" : "arguments.\(position)"
    }
}
