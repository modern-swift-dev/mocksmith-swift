import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Type-erases generated protocol member models.
enum GeneratedMember {
    case function(FunctionMember)
    case property(PropertyMember)
    case subscriptMember(SubscriptMember)

    var channelName: String {
        switch self { case let .function(x): x.channelName; case let .property(x): x.channelName; case let .subscriptMember(x): x.channelName }
    }

    var displayName: String {
        switch self { case let .function(x): x.displayName; case let .property(x): x.displayName; case let .subscriptMember(x): x.displayName }
    }

    var argumentsType: String {
        switch self { case let .function(x): x.argumentsType; case let .property(x): x.argumentsType; case let .subscriptMember(x): x.argumentsType }
    }

    var outputType: String {
        switch self { case let .function(x): x.outputType; case let .property(x): x.outputType; case let .subscriptMember(x): x.outputType }
    }

    var isTransient: Bool {
        switch self { case let .function(x): x.isTransient; case let .property(x): x.isTransient; case let .subscriptMember(x): x.isTransient }
    }

    var channelType: String {
        let ephemeral = if case let .function(value) = self {
            value.ephemeralArgumentsType
        } else {
            "Void"
        }
        return "\(isTransient ? "TransientMockMember" : "MockMember")<\(argumentsType), \(ephemeral), \(outputType)>"
    }

    var channelConstructor: String {
        "\(channelType)(name: \"\(displayName)\")"
    }

    var isStatic: Bool {
        switch self { case let .function(x): x.isStatic; case let .property(x): x.isStatic; case let .subscriptMember(x): x.isStatic }
    }

    var isGeneric: Bool {
        switch self { case let .function(x): x.isGeneric; case .property: false; case let .subscriptMember(x): x.isGeneric }
    }

    var usesRegistry: Bool {
        switch self { case let .function(x): x.usesRegistry; case let .property(x): x.usesRegistry; case let .subscriptMember(x): x.usesRegistry }
    }

    var witness: String {
        switch self { case let .function(x): x.witness; case let .property(x): x.witness; case let .subscriptMember(x): x.witness }
    }

    var givenFactory: String {
        switch self { case let .function(x): x.givenFactory; case let .property(x): x.givenFactory; case let .subscriptMember(x): x.givenFactory }
    }

    var verifyFactory: String {
        switch self { case let .function(x): x.verifyFactory; case let .property(x): x.verifyFactory; case let .subscriptMember(x): x.verifyFactory }
    }

    var callsFactory: String {
        switch self { case let .function(x): x.callsFactory; case let .property(x): x.callsFactory; case let .subscriptMember(x): x.callsFactory }
    }

    var stateFactory: String {
        switch self {
            case .function,
                 .subscriptMember:
                ""
            case let .property(x):
                x.stateFactory
        }
    }

    var orderFactory: String {
        switch self { case let .function(x): x.orderFactory; case let .property(x): x.orderFactory; case let .subscriptMember(x): x.orderFactory }
    }

    var performFactory: String {
        switch self { case let .function(x): x.performFactory; case let .property(x): x.performFactory; case let .subscriptMember(x): x.performFactory }
    }

    var argumentsStructDeclaration: String? {
        switch self { case let .function(value): value.argumentsStructDeclaration; case let .subscriptMember(value): value.argumentsStructDeclaration; case .property: nil }
    }
}
