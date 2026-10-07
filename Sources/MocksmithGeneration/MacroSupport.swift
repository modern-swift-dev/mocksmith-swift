import Foundation
import SwiftSyntax

private func hasAvailabilityAttribute(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else {
            return false
        }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last == "available"
    }
}

func hasAttribute(named expected: String, in attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else {
            return false
        }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last == Substring(expected)
    }
}

func availabilityAttributes(_ attributes: AttributeListSyntax) -> String {
    attributes.compactMap { element -> String? in
        guard let attribute = element.as(AttributeSyntax.self),
              attribute.attributeName.trimmedDescription.split(separator: ".").last == "available" else {
            return nil
        }
        return attribute.trimmedDescription
    }.joined(separator: "\n")
}

func witnessAttributePrefix(_ attributes: AttributeListSyntax, indentation: String) -> String {
    let values = attributes.compactMap { element -> String? in
        guard let attribute = element.as(AttributeSyntax.self) else {
            return nil
        }
        let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        guard !["available", "MockNoncopyable"].contains(name) else {
            return nil
        }
        return indentation + attribute.trimmedDescription
    }
    return values.isEmpty ? "" : values.joined(separator: "\n") + "\n"
}

/// Detects a `set` requirement by token, so a getter effect such as
/// `throws(OffsetError)` cannot be mistaken for a setter.
package func hasSetter(_ block: AccessorBlockSyntax?) -> Bool {
    guard let block, case let .accessors(accessors) = block.accessors else {
        return false
    }
    return accessors.contains { $0.accessorSpecifier.tokenKind == .keyword(.set) }
}

/// Finds a `~Copyable` suppression anywhere in a declaration without
/// serializing it, so the check is structural and cheap.
func containsNoncopyableSuppression(_ node: some SyntaxProtocol) -> Bool {
    let finder = NoncopyableSuppressionFinder(viewMode: .sourceAccurate)
    finder.walk(node)
    return finder.found
}

/// Returns whether a requirement is transient: marked `@MockNoncopyable`
/// or mentioning `~Copyable` in its signature.
func isTransientRequirement(_ declaration: some WithAttributesSyntax) -> Bool {
    hasAttribute(named: "MockNoncopyable", in: declaration.attributes)
        || containsNoncopyableSuppression(declaration)
}

private final class NoncopyableSuppressionFinder: SyntaxVisitor {
    var found = false

    override func visit(_ node: SuppressedTypeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.type.as(IdentifierTypeSyntax.self)?.name.text
            ?? node.type.as(MemberTypeSyntax.self)?.name.text
        if name == "Copyable" {
            found = true
        }
        return .skipChildren
    }
}

func accessorHeader(_ accessor: AccessorDeclSyntax) -> String {
    var copy = accessor
    copy.body = nil
    copy.attributes = []
    return copy.trimmedDescription
}

/// Effects declared on a requirement, read structurally rather than from the
/// trimmed text of the effect specifiers.
struct DeclaredEffects {
    let isAsync: Bool
    let isThrowing: Bool
    let isRethrows: Bool
    let typedError: String?

    init(_ effects: FunctionEffectSpecifiersSyntax?) {
        isAsync = effects?.asyncSpecifier != nil
        isThrowing = effects?.throwsClause != nil
        isRethrows = effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.rethrows)
        typedError = typedErrorName(effects?.throwsClause?.type)
    }

    init(_ effects: AccessorEffectSpecifiersSyntax?) {
        isAsync = effects?.asyncSpecifier != nil
        isThrowing = effects?.throwsClause != nil
        isRethrows = false
        typedError = typedErrorName(effects?.throwsClause?.type)
    }
}

/// The explicit error type of a `throws(E)` clause, or nil for untyped throws.
func typedErrorName(_ type: TypeSyntax?) -> String? {
    guard let type = type?.trimmedDescription else {
        return nil
    }
    return ["Error", "any Error", "any Swift.Error"].contains(type) ? nil : type
}

func stableIdentifier(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

func objectIdentifierList(_ metatypes: String) -> String {
    let values = metatypes.split(separator: ",").map { "ObjectIdentifier(\($0.trimmingCharacters(in: .whitespaces)))" }
    return "[\(values.joined(separator: ", "))]"
}

func strippingEscapingAttribute(from type: String) -> String {
    type.replacingOccurrences(of: "@escaping\\s*", with: "", options: .regularExpression)
}

/// Returns whether a type is structurally an optional, without confusing a
/// function that returns an optional or an optional metatype for an optional
/// result itself.
func isOptionalType(_ type: TypeSyntax) -> Bool {
    if type.as(OptionalTypeSyntax.self) != nil {
        return true
    }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return isOptionalType(attributed.baseType)
    }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
       let element = tuple.elements.first {
        return isOptionalType(element.type)
    }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifier.name.text == "Optional"
    }
    if let member = type.as(MemberTypeSyntax.self),
       member.name.text == "Optional",
       let base = member.baseType.as(IdentifierTypeSyntax.self) {
        return base.name.text == "Swift"
    }
    return false
}

func isVoidType(_ type: TypeSyntax) -> Bool {
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return isVoidType(attributed.baseType)
    }
    if let tuple = type.as(TupleTypeSyntax.self) {
        if tuple.elements.isEmpty {
            return true
        }
        if tuple.elements.count == 1, let element = tuple.elements.first {
            return isVoidType(element.type)
        }
        return false
    }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifier.name.text == "Void"
    }
    if let member = type.as(MemberTypeSyntax.self),
       member.name.text == "Void",
       let base = member.baseType.as(IdentifierTypeSyntax.self) {
        return base.name.text == "Swift"
    }
    return false
}

func opaqueParameterType(_ text: String, position: Int) -> (name: String, constraint: String)? {
    var type = text
    for prefix in ["inout ", "borrowing ", "consuming ", "sending "] where type.hasPrefix(prefix) {
        type.removeFirst(prefix.count)
    }
    guard type.hasPrefix("some ") else {
        return nil
    }
    return ("_MockOpaque\(position)", String(type.dropFirst(5)))
}

/// Only a directly spelled function parameter is implicitly nonescaping.
/// Optional functions and functions inside containers are ordinary stored values.
func isNonescapingClosure(_ type: TypeSyntax) -> Bool {
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return !hasAttribute(named: "escaping", in: attributed.attributes)
            && isNonescapingClosure(attributed.baseType)
    }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
       let element = tuple.elements.first {
        return isNonescapingClosure(element.type)
    }
    return type.is(FunctionTypeSyntax.self)
}

func rewriteType(_ syntax: some SyntaxProtocol, replacements: [String: String], mockType: String) -> String {
    // Only the rewritten text is used; rebuilding the enclosing declaration is unnecessary.
    TypeReferenceRewriter(replacements: replacements, mockType: mockType)
        .rewrite(syntax, detach: true).trimmedDescription
}

private final class TypeReferenceRewriter: SyntaxRewriter {
    let replacements: [String: String]
    let mockType: String

    init(replacements: [String: String], mockType: String) {
        self.replacements = replacements
        self.mockType = mockType
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        var node = node
        if let replacement = replacements[node.name.text] ?? (node.name.text == "Self" ? mockType : nil) {
            node.name = .identifier(replacement, leadingTrivia: node.name.leadingTrivia, trailingTrivia: node.name.trailingTrivia)
        }
        return super.visit(node)
    }

    override func visit(_ node: MemberTypeSyntax) -> TypeSyntax {
        if let base = node.baseType.as(IdentifierTypeSyntax.self), base.name.text == "Self",
           let replacement = replacements[node.name.text] {
            return TypeSyntax(IdentifierTypeSyntax(
                leadingTrivia: node.leadingTrivia,
                name: .identifier(replacement),
                genericArgumentClause: node.genericArgumentClause,
                trailingTrivia: node.trailingTrivia
            ))
        }
        // Rewriting the base preserves member names such as T.Element.
        return super.visit(node)
    }
}

extension String {
    mutating func replaceFirst(_ target: String, with replacement: String) {
        guard let range = range(of: target) else {
            return
        }
        replaceSubrange(range, with: replacement)
    }
}
