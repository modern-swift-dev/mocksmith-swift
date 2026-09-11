import Foundation
import MocksmithGeneration
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion

private let markerOrder = ["AnyObject", "Sendable", "Actor", "~Copyable", "NSObjectProtocol"]
private let markerNames = Set(markerOrder)

private struct Arguments {
    let output: URL
    let targetModule: String
    let modules: [ModuleInput]

    init(_ values: [String]) throws {
        var output: URL?
        var targetModule: String?
        var modules: [ModuleInput] = []
        var index = 0

        while index < values.count {
            switch values[index] {
                case "--output":
                    index += 1
                    guard index < values.count else {
                        throw GeneratorError.usage("missing value after --output")
                    }
                    output = URL(fileURLWithPath: values[index])
                    index += 1
                case "--target-module":
                    index += 1
                    guard index < values.count else {
                        throw GeneratorError.usage("missing value after --target-module")
                    }
                    targetModule = values[index]
                    index += 1
                case "--module":
                    index += 1
                    guard index < values.count else {
                        throw GeneratorError.usage("missing module name after --module")
                    }
                    let name = values[index]
                    index += 1
                    var paths: [String] = []
                    while index < values.count, !values[index].hasPrefix("--") {
                        paths.append(values[index])
                        index += 1
                    }
                    guard !paths.isEmpty else {
                        throw GeneratorError.usage("--module \(name) has no source files")
                    }
                    modules.append(ModuleInput(name: name, paths: paths))
                default:
                    throw GeneratorError.usage("unknown argument '\(values[index])'")
            }
        }

        guard let output else {
            throw GeneratorError.usage("missing --output")
        }
        guard let targetModule else {
            throw GeneratorError.usage("missing --target-module")
        }
        guard modules.contains(where: { $0.name == targetModule }) else {
            throw GeneratorError.usage("target module '\(targetModule)' is not present in --module inputs")
        }

        self.output = output
        self.targetModule = targetModule
        self.modules = modules
    }
}

private struct MockGenerationInput: Codable, Equatable {
    let protocolSource: String
    let mockType: String
    let conformanceType: String
    let access: String
    let isActor: Bool
}

private struct GenerationInput: Codable, Equatable {
    let targetModule: String
    let mocks: [MockGenerationInput]
    let imports: [String]
}

private struct GeneratorIdentity: Codable, Equatable {
    let executablePath: String
    let modificationDate: Date
    let size: UInt64
    let inode: UInt64

    static func current() -> Self? {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? UInt64,
              let inode = attributes[.systemFileNumber] as? UInt64 else {
            // Without trustworthy tool metadata, render normally on every invocation.
            return nil
        }
        return Self(executablePath: executable.path, modificationDate: modificationDate, size: size, inode: inode)
    }
}

private struct GenerationCache: Codable {
    let generator: GeneratorIdentity?
    let input: GenerationInput
    let source: String
}

private struct PreparedMock {
    let input: MockGenerationInput
    let generator: MockGenerator
}

private struct ModuleInput {
    let name: String
    let paths: [String]
}

private struct DeclarationID: Hashable, CustomStringConvertible {
    let module: String
    let name: String

    var description: String {
        "\(module).\(name)"
    }
}

private struct SourceUnit {
    let module: String
    let path: String
    let tree: SourceFileSyntax
    let importedModules: Set<String>
    let imports: CodeBlockItemListSyntax

    func location(of node: some SyntaxProtocol) -> SourceDiagnostic.Location {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return .init(path: path, line: location.line, column: location.column)
    }
}

private struct ProtocolRecord {
    let id: DeclarationID
    let declaration: ProtocolDeclSyntax
    let unit: Int
}

private struct AliasRecord {
    let id: DeclarationID
    let declaration: TypeAliasDeclSyntax
    let unit: Int
}

private enum AccessLevel: String {
    case internalAccess = "internal"
    case package
    case `public`

    static func read(from record: ProtocolRecord, units: [SourceUnit]) throws -> Self {
        let modifiers = Set(record.declaration.modifiers.map(\.name.text))
        if modifiers.contains("private") || modifiers.contains("fileprivate") {
            throw GeneratorError.source(
                units[record.unit].location(of: record.declaration),
                "@Mockable build plugin generation requires an internal, package, or public top-level protocol"
            )
        }
        if modifiers.contains("public") {
            return .public
        }
        if modifiers.contains("package") {
            return .package
        }
        return .internalAccess
    }
}

private struct TypeReference {
    let module: String?
    let name: String
    let hasGenericArguments: Bool
}

private enum ResolvedDeclaration: Hashable {
    case protocolDecl(DeclarationID)
    case alias(DeclarationID)
}

private struct FlattenedProtocol {
    let records: [ProtocolRecord]
    let aliases: [AliasRecord]
    let members: [MemberBlockItemSyntax]
    let markers: Set<String>
    let attributes: [AttributeSyntax]
    let whereRequirements: [String]
}

private struct SourceDiagnostic: Error {
    struct Location {
        let path: String
        let line: Int
        let column: Int
    }

    let location: Location
    let message: String
}

private enum GeneratorError: Error {
    case usage(String)
    case source(SourceDiagnostic.Location, String)
}

private final class Scanner {
    private let targetModule: String
    private let units: [SourceUnit]
    private let availableSourceModules: Set<String>
    private var protocols: [DeclarationID: [ProtocolRecord]] = [:]
    private var aliases: [DeclarationID: [AliasRecord]] = [:]

    init(arguments: Arguments) throws {
        let targetModule = arguments.targetModule
        self.targetModule = targetModule
        availableSourceModules = Set(arguments.modules.map(\.name))

        let sortedModules = arguments.modules.sorted(by: { $0.name < $1.name })
        let targetInputs = sortedModules.filter { $0.name == targetModule }
        let targetCandidates = try Self.parse(targetInputs, onlyMockableCandidates: true)
        try validateBuildPluginDeclarations(targetCandidates)
        let parsed = try targetCandidates.contains(where: requiresDependencySources)
            ? Self.parse(sortedModules)
            : targetCandidates
        units = parsed

        for (unitIndex, unit) in units.enumerated() {
            for item in unit.tree.statements {
                if let declaration = item.item.as(ProtocolDeclSyntax.self) {
                    let record = ProtocolRecord(
                        id: .init(module: unit.module, name: declaration.name.text),
                        declaration: declaration,
                        unit: unitIndex
                    )
                    protocols[record.id, default: []].append(record)
                } else if let declaration = item.item.as(TypeAliasDeclSyntax.self) {
                    let record = AliasRecord(
                        id: .init(module: unit.module, name: declaration.name.text),
                        declaration: declaration,
                        unit: unitIndex
                    )
                    aliases[record.id, default: []].append(record)
                }
            }
        }
    }

    private static func parse(
        _ modules: [ModuleInput],
        onlyMockableCandidates: Bool = false
    ) throws -> [SourceUnit] {
        var units: [SourceUnit] = []
        for module in modules {
            for path in module.paths.sorted() {
                let url = URL(fileURLWithPath: path)
                let source: String
                do {
                    source = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw GeneratorError.source(
                        .init(path: path, line: 1, column: 1),
                        "cannot read source: \(error.localizedDescription)"
                    )
                }
                if onlyMockableCandidates, !source.contains("Mockable") {
                    continue
                }
                let tree = Parser.parse(source: source)
                let imports = tree.statements.compactMap { $0.item.as(ImportDeclSyntax.self) }
                units.append(
                    SourceUnit(
                        module: module.name,
                        path: path,
                        tree: tree,
                        importedModules: Set(imports.compactMap { $0.path.first?.name.text }),
                        imports: importStatements(in: tree.statements)
                    )
                )
            }
        }
        return units
    }

    func render(cached: GenerationCache?, identity: GeneratorIdentity?) throws -> GenerationCache {
        let roots = protocols.values
            .flatMap(\.self)
            .filter {
                $0.id.module == targetModule
                    && hasAttribute(named: "Mockable", in: $0.declaration.attributes)
                    && (hasCustomInheritance($0.declaration) || requestsBuildPlugin($0.declaration))
            }
            .sorted {
                if $0.id.name != $1.id.name {
                    return $0.id.name < $1.id.name
                }
                return units[$0.unit].path < units[$1.unit].path
            }

        var preparedMocks: [PreparedMock] = []
        var importTexts = Set(["import Mocksmith"])
        for root in roots {
            if protocols[root.id]?.count != 1 {
                throw sourceError(at: root, "ambiguous top-level protocol '\(root.id.name)' in module '\(root.id.module)'")
            }
            let access = try AccessLevel.read(from: root, units: units)
            let flattened = try flatten(root)
            preparedMocks.append(try prepareMock(root: root, access: access, flattened: flattened))

            let contributingUnits = Set(flattened.records.map(\.unit) + flattened.aliases.map(\.unit))
            for unitIndex in contributingUnits {
                let unit = units[unitIndex]
                if unit.module != targetModule {
                    importTexts.insert("import \(unit.module)")
                }
                for statement in importStatements(in: unit.imports, excluding: targetModule) {
                    importTexts.insert(statement.trimmedDescription)
                }
            }
        }

        let input = GenerationInput(
            targetModule: targetModule,
            mocks: preparedMocks.map(\.input),
            imports: importTexts.sorted()
        )
        if let identity, let cached, cached.generator == identity, cached.input == input {
            return cached
        }
        let sections = preparedMocks.map { $0.generator.render() }
        let imports = input.imports.joined(separator: "\n")
        let body = sections.isEmpty ? "" : "\n\n" + sections.joined(separator: "\n\n")
        let source = "// Generated by MocksmithGenerator. Do not edit.\n\(imports)\(body)\n"
        return GenerationCache(generator: identity, input: input, source: source)
    }

    private func flatten(_ root: ProtocolRecord) throws -> FlattenedProtocol {
        var visiting = Set<ResolvedDeclaration>()
        var visitedProtocols = Set<DeclarationID>()
        var visitedAliases = Set<DeclarationID>()
        var orderedProtocols: [ProtocolRecord] = []
        var orderedAliases: [AliasRecord] = []
        var markers = Set<String>()

        func visitReference(_ reference: TypeReference, from unit: Int) throws {
            if markerNames.contains(reference.name) {
                markers.insert(reference.name)
                return
            }
            if reference.hasGenericArguments {
                throw GeneratorError.source(
                    units[unit].location(of: units[unit].tree),
                    "generic inherited protocol references are not supported: '\(reference.name)'"
                )
            }
            switch try resolve(reference, from: unit) {
                case let .protocolDecl(id):
                    try visitProtocol(try uniqueProtocol(id, referencedFrom: unit))
                case let .alias(id):
                    try visitAlias(try uniqueAlias(id, referencedFrom: unit))
            }
        }

        func visitProtocol(_ record: ProtocolRecord) throws {
            guard !visitedProtocols.contains(record.id) else {
                return
            }
            let node = ResolvedDeclaration.protocolDecl(record.id)
            guard visiting.insert(node).inserted else {
                throw sourceError(at: record, "protocol inheritance cycle involving '\(record.id)'")
            }
            defer { visiting.remove(node) }

            for inherited in record.declaration.inheritanceClause?.inheritedTypes ?? [] {
                for reference in try references(in: inherited.type, unit: record.unit) {
                    try visitReference(reference, from: record.unit)
                }
            }
            visitedProtocols.insert(record.id)
            orderedProtocols.append(record)
        }

        func visitAlias(_ record: AliasRecord) throws {
            guard !visitedAliases.contains(record.id) else {
                return
            }
            if record.declaration.genericParameterClause != nil || record.declaration.genericWhereClause != nil {
                throw sourceError(at: record, "generic protocol-composition alias '\(record.id)' is not supported")
            }
            let node = ResolvedDeclaration.alias(record.id)
            guard visiting.insert(node).inserted else {
                throw sourceError(at: record, "protocol-composition alias cycle involving '\(record.id)'")
            }
            defer { visiting.remove(node) }

            for reference in try references(in: record.declaration.initializer.value, unit: record.unit) {
                try visitReference(reference, from: record.unit)
            }
            visitedAliases.insert(record.id)
            orderedAliases.append(record)
        }

        try visitProtocol(root)

        var memberOrder: [String] = []
        var membersByKey: [String: MemberBlockItemSyntax] = [:]
        var attributes: [AttributeSyntax] = []
        var seenAttributes = Set<String>()
        var whereRequirements: [String] = []
        var seenRequirements = Set<String>()

        for record in orderedProtocols {
            for member in record.declaration.memberBlock.members {
                let key = memberKey(member.decl)
                if membersByKey[key] == nil {
                    memberOrder.append(key)
                }
                membersByKey[key] = membersByKey[key].map { mergeRequirements($0, member) } ?? member
            }
            for element in record.declaration.attributes {
                guard let attribute = element.as(AttributeSyntax.self), isRelevant(attribute) else {
                    continue
                }
                let text = attribute.trimmedDescription
                if seenAttributes.insert(text).inserted {
                    attributes.append(attribute)
                }
            }
            for requirement in record.declaration.genericWhereClause?.requirements ?? [] {
                let text = requirement.trimmedDescription
                if seenRequirements.insert(text).inserted {
                    whereRequirements.append(text)
                }
            }
        }

        return FlattenedProtocol(
            records: orderedProtocols,
            aliases: orderedAliases,
            members: memberOrder.compactMap { membersByKey[$0] },
            markers: markers,
            attributes: attributes,
            whereRequirements: whereRequirements
        )
    }

    private func resolve(_ reference: TypeReference, from unit: Int) throws -> ResolvedDeclaration {
        if let module = reference.module {
            guard availableSourceModules.contains(module) else {
                throw GeneratorError.source(
                    units[unit].location(of: units[unit].tree),
                    "inherited protocol '\(module).\(reference.name)' has no readable source available; binary, SDK, and precompiled modules are unsupported"
                )
            }
            return try resolvedDeclaration(.init(module: module, name: reference.name), referencedFrom: unit)
        }

        let local = DeclarationID(module: units[unit].module, name: reference.name)
        if protocols[local] != nil || aliases[local] != nil {
            return try resolvedDeclaration(local, referencedFrom: unit)
        }

        let candidates = units[unit].importedModules
            .filter(availableSourceModules.contains)
            .map { DeclarationID(module: $0, name: reference.name) }
            .filter { protocols[$0] != nil || aliases[$0] != nil }
            .sorted { $0.description < $1.description }

        guard candidates.count == 1, let candidate = candidates.first else {
            let detail = candidates.isEmpty
                ? "cannot resolve inherited protocol or composition alias '\(reference.name)' in target module '\(targetModule)' or its reachable SwiftPM source dependencies; binary, SDK, and precompiled modules are unsupported"
                : "ambiguous inherited name '\(reference.name)': \(candidates.map(\.description).joined(separator: ", "))"
            throw GeneratorError.source(units[unit].location(of: units[unit].tree), detail)
        }
        return try resolvedDeclaration(candidate, referencedFrom: unit)
    }

    private func resolvedDeclaration(_ id: DeclarationID, referencedFrom unit: Int) throws -> ResolvedDeclaration {
        let protocolCount = protocols[id]?.count ?? 0
        let aliasCount = aliases[id]?.count ?? 0
        guard protocolCount + aliasCount == 1 else {
            let message = protocolCount + aliasCount == 0
                ? "cannot resolve inherited name '\(id)'"
                : "ambiguous inherited declaration '\(id)'"
            throw GeneratorError.source(units[unit].location(of: units[unit].tree), message)
        }
        return protocolCount == 1 ? .protocolDecl(id) : .alias(id)
    }

    private func uniqueProtocol(_ id: DeclarationID, referencedFrom unit: Int) throws -> ProtocolRecord {
        guard let values = protocols[id], values.count == 1, let value = values.first else {
            throw GeneratorError.source(units[unit].location(of: units[unit].tree), "ambiguous protocol '\(id)'")
        }
        return value
    }

    private func uniqueAlias(_ id: DeclarationID, referencedFrom unit: Int) throws -> AliasRecord {
        guard let values = aliases[id], values.count == 1, let value = values.first else {
            throw GeneratorError.source(units[unit].location(of: units[unit].tree), "ambiguous typealias '\(id)'")
        }
        return value
    }

    private func references(in type: TypeSyntax, unit: Int) throws -> [TypeReference] {
        if markerNames.contains(simpleName(type.trimmedDescription)) {
            return [.init(module: nil, name: simpleName(type.trimmedDescription), hasGenericArguments: false)]
        }
        if let composition = type.as(CompositionTypeSyntax.self) {
            return try composition.elements.flatMap { try references(in: $0.type, unit: unit) }
        }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return [
                .init(
                    module: nil,
                    name: identifier.name.text,
                    hasGenericArguments: identifier.genericArgumentClause != nil
                )
            ]
        }
        if let member = type.as(MemberTypeSyntax.self),
           let base = member.baseType.as(IdentifierTypeSyntax.self),
           base.genericArgumentClause == nil {
            return [
                .init(
                    module: base.name.text,
                    name: member.name.text,
                    hasGenericArguments: member.genericArgumentClause != nil
                )
            ]
        }
        throw GeneratorError.source(
            units[unit].location(of: type),
            "unsupported inherited type syntax '\(type.trimmedDescription)'"
        )
    }

    private func prepareMock(
        root: ProtocolRecord,
        access: AccessLevel,
        flattened: FlattenedProtocol
    ) throws -> PreparedMock {
        let declaration = try hasCustomInheritance(root.declaration)
            ? resolvedProtocol(root: root, flattened: flattened)
            : root.declaration
        let input = MockGenerationInput(
            protocolSource: declaration.description,
            mockType: root.declaration.name.text + "Mock",
            conformanceType: root.declaration.name.trimmedDescription,
            access: access == .internalAccess ? "" : access.rawValue + " ",
            isActor: flattened.markers.contains("Actor")
        )
        let generator = MockGenerator(
            protocolDecl: declaration,
            isActor: input.isActor,
            mockType: input.mockType,
            conformanceType: input.conformanceType,
            access: input.access
        )
        let context = BasicMacroExpansionContext(lexicalContext: [])
        let valid = generator.validate(in: context)
        for diagnostic in context.diagnostics {
            // Resolved requirements may come from several files. Anchor their diagnostics
            // to the annotated root, whose source is always available to the build system.
            let location = units[root.unit].location(of: root.declaration)
            if diagnostic.diagMessage.severity == .error {
                throw GeneratorError.source(location, diagnostic.message)
            }
            FileHandle.standardError.write(Data(
                "\(location.path):\(location.line):\(location.column): warning: \(diagnostic.message)\n".utf8
            ))
        }
        guard valid else {
            throw sourceError(at: root, "cannot generate mock for '\(root.id.name)'")
        }
        return PreparedMock(input: input, generator: generator)
    }

    private func resolvedProtocol(
        root: ProtocolRecord,
        flattened: FlattenedProtocol
    ) throws -> ProtocolDeclSyntax {
        let attributeLines = flattened.attributes.map(\.trimmedDescription)
        let carrierName = "__MocksmithResolved_\(sanitize(targetModule))_\(sanitize(root.id.name))"
        let primary = root.declaration.primaryAssociatedTypeClause?.trimmedDescription ?? ""
        let inherited = markerOrder.filter(flattened.markers.contains)
        let inheritance = inherited.isEmpty ? "" : ": " + inherited.joined(separator: ", ")
        let whereClause = flattened.whereRequirements.isEmpty
            ? ""
            : " where " + flattened.whereRequirements.joined(separator: ", ")
        let members = flattened.members
            .map { indent($0.decl.trimmedDescription, by: 4) }
            .joined(separator: "\n")
        let source = """
        \(attributeLines.joined(separator: "\n"))
        private protocol \(carrierName)\(primary)\(inheritance)\(whereClause) {
        \(members)
        }
        """
        let tree = Parser.parse(source: source)
        guard !tree.hasError,
              let declaration = tree.statements.first?.item.as(ProtocolDeclSyntax.self) else {
            throw sourceError(at: root, "cannot parse resolved protocol '\(root.id.name)'")
        }
        return declaration
    }

    private func sourceError(at record: ProtocolRecord, _ message: String) -> GeneratorError {
        .source(units[record.unit].location(of: record.declaration), message)
    }

    private func sourceError(at record: AliasRecord, _ message: String) -> GeneratorError {
        .source(units[record.unit].location(of: record.declaration), message)
    }
}

/// Preserves import conditions without copying unrelated source declarations.
private func importStatements(
    in statements: CodeBlockItemListSyntax,
    excluding module: String? = nil
) -> CodeBlockItemListSyntax {
    CodeBlockItemListSyntax(statements.compactMap { item -> CodeBlockItemSyntax? in
        if let declaration = item.item.as(ImportDeclSyntax.self) {
            return declaration.path.first?.name.text == module ? nil : item
        }
        guard var conditional = item.item.as(IfConfigDeclSyntax.self) else {
            return nil
        }
        var containsImports = false
        conditional.clauses = IfConfigClauseListSyntax(conditional.clauses.map { clause in
            var clause = clause
            let statements = clause.elements?.as(CodeBlockItemListSyntax.self) ?? []
            let imports = importStatements(in: statements, excluding: module)
            containsImports = containsImports || !imports.isEmpty
            clause.elements = .statements(imports)
            return clause
        })
        guard containsImports else {
            return nil
        }
        var result = item
        result.item = .decl(DeclSyntax(conditional))
        return result
    })
}

private final class BuildPluginDeclarationVisitor: SyntaxVisitor {
    private var conditionalDepth = 0
    private(set) var conditionalDeclarations: [ProtocolDeclSyntax] = []
    private(set) var nestedDeclarations: [ProtocolDeclSyntax] = []

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        conditionalDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: IfConfigDeclSyntax) {
        conditionalDepth -= 1
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if requestsBuildPlugin(node) {
            if conditionalDepth > 0 {
                conditionalDeclarations.append(node)
            } else if node.parent?.parent?.parent?.is(SourceFileSyntax.self) != true {
                nestedDeclarations.append(node)
            }
        }
        return .visitChildren
    }
}

private func validateBuildPluginDeclarations(_ units: [SourceUnit]) throws {
    for unit in units {
        let visitor = BuildPluginDeclarationVisitor(viewMode: .sourceAccurate)
        visitor.walk(unit.tree)
        if let declaration = visitor.conditionalDeclarations.first {
            throw GeneratorError.source(
                unit.location(of: declaration),
                "@Mockable build plugin generation requires an unconditional top-level protocol"
            )
        }
        if let declaration = visitor.nestedDeclarations.first {
            throw GeneratorError.source(
                unit.location(of: declaration),
                "@Mockable build plugin generation requires an internal, package, or public top-level protocol"
            )
        }
    }
}

private func requiresDependencySources(_ unit: SourceUnit) -> Bool {
    unit.tree.statements.contains {
        guard let declaration = $0.item.as(ProtocolDeclSyntax.self) else {
            return false
        }
        return hasAttribute(named: "Mockable", in: declaration.attributes)
            && hasCustomInheritance(declaration)
    }
}

private func hasCustomInheritance(_ declaration: ProtocolDeclSyntax) -> Bool {
    declaration.inheritanceClause?.inheritedTypes.contains {
        !markerNames.contains(simpleName($0.type.trimmedDescription))
    } == true
}

private func requestsBuildPlugin(_ declaration: ProtocolDeclSyntax) -> Bool {
    declaration.attributes.contains {
        guard let attribute = $0.as(AttributeSyntax.self),
              simpleName(attribute.attributeName.trimmedDescription) == "Mockable" else {
            return false
        }
        return MockGenerationMode(attribute) == .buildPlugin
    }
}

private func hasAttribute(named expected: String, in attributes: AttributeListSyntax) -> Bool {
    attributes.contains {
        guard let attribute = $0.as(AttributeSyntax.self) else {
            return false
        }
        return simpleName(attribute.attributeName.trimmedDescription) == expected
    }
}

private func isRelevant(_ attribute: AttributeSyntax) -> Bool {
    let name = simpleName(attribute.attributeName.trimmedDescription)
    return name == "available" || name == "objc" || (name.hasSuffix("Actor") && name != "Mockable")
}

private func simpleName(_ text: String) -> String {
    text.split(separator: ".").last.map(String.init) ?? text
}

/// Keeps requirements contributed by every parent when declarations share a witness.
private func mergeRequirements(
    _ inherited: MemberBlockItemSyntax,
    _ redeclared: MemberBlockItemSyntax
) -> MemberBlockItemSyntax {
    var result = redeclared
    if let previous = inherited.decl.as(AssociatedTypeDeclSyntax.self),
       var current = redeclared.decl.as(AssociatedTypeDeclSyntax.self) {
        var seenTypes = Set<String>()
        var inheritedTypes = Array(previous.inheritanceClause?.inheritedTypes ?? [])
        inheritedTypes.append(contentsOf: current.inheritanceClause?.inheritedTypes ?? [])
        inheritedTypes = inheritedTypes.filter { seenTypes.insert($0.type.trimmedDescription).inserted }
        if var clause = current.inheritanceClause ?? previous.inheritanceClause {
            for index in inheritedTypes.indices {
                inheritedTypes[index].trailingComma = index < inheritedTypes.count - 1
                    ? .commaToken(trailingTrivia: .space) : nil
            }
            clause.inheritedTypes = InheritedTypeListSyntax(inheritedTypes)
            current.inheritanceClause = clause
        }

        var seenRequirements = Set<String>()
        var requirements = Array(previous.genericWhereClause?.requirements ?? [])
        requirements.append(contentsOf: current.genericWhereClause?.requirements ?? [])
        requirements = requirements.filter { seenRequirements.insert($0.requirement.trimmedDescription).inserted }
        if var clause = current.genericWhereClause ?? previous.genericWhereClause {
            for index in requirements.indices {
                requirements[index].trailingComma = index < requirements.count - 1
                    ? .commaToken(trailingTrivia: .space) : nil
            }
            clause.requirements = GenericRequirementListSyntax(requirements)
            current.genericWhereClause = clause
        }
        result.decl = DeclSyntax(current)
    } else if let previous = inherited.decl.as(VariableDeclSyntax.self),
              var current = redeclared.decl.as(VariableDeclSyntax.self),
              let previousBinding = previous.bindings.first,
              var currentBinding = current.bindings.first,
              hasSetter(previousBinding.accessorBlock), !hasSetter(currentBinding.accessorBlock) {
        currentBinding.accessorBlock = previousBinding.accessorBlock
        current.bindings = PatternBindingListSyntax([currentBinding])
        result.decl = DeclSyntax(current)
    } else if let previous = inherited.decl.as(SubscriptDeclSyntax.self),
              var current = redeclared.decl.as(SubscriptDeclSyntax.self),
              hasSetter(previous.accessorBlock), !hasSetter(current.accessorBlock) {
        current.accessorBlock = previous.accessorBlock
        result.decl = DeclSyntax(current)
    }
    return result
}

private func hasSetter(_ block: AccessorBlockSyntax?) -> Bool {
    guard let block, case let .accessors(accessors) = block.accessors else {
        return false
    }
    return accessors.contains { $0.accessorSpecifier.tokenKind == .keyword(.set) }
}

private func memberKey(_ declaration: DeclSyntax) -> String {
    let staticPrefix: String = {
        if let value = declaration.as(FunctionDeclSyntax.self) {
            return value.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) ? "static:" : ""
        }
        if let value = declaration.as(VariableDeclSyntax.self) {
            return value.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) ? "static:" : ""
        }
        if let value = declaration.as(SubscriptDeclSyntax.self) {
            return value.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) ? "static:" : ""
        }
        return ""
    }()

    if let value = declaration.as(AssociatedTypeDeclSyntax.self) {
        return "associatedtype:\(value.name.text)"
    }
    if let value = declaration.as(TypeAliasDeclSyntax.self) {
        return "typealias:\(value.name.text)"
    }
    if let value = declaration.as(VariableDeclSyntax.self),
       let name = value.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
        return "property:\(staticPrefix)\(name)"
    }
    if let value = declaration.as(FunctionDeclSyntax.self) {
        let parameters = value.signature.parameterClause.parameters.map {
            "\($0.firstName.text):\($0.type.trimmedDescription)"
        }.joined(separator: ",")
        return "function:\(staticPrefix)\(value.name.text)\(value.genericParameterClause?.trimmedDescription ?? "")(\(parameters))\(value.signature.effectSpecifiers?.trimmedDescription ?? "")\(value.signature.returnClause?.trimmedDescription ?? "")\(value.genericWhereClause?.trimmedDescription ?? "")"
    }
    if let value = declaration.as(SubscriptDeclSyntax.self) {
        let parameters = value.parameterClause.parameters.map {
            "\($0.firstName.text):\($0.type.trimmedDescription)"
        }.joined(separator: ",")
        return "subscript:\(staticPrefix)\(value.genericParameterClause?.trimmedDescription ?? "")(\(parameters))\(value.returnClause.trimmedDescription)\(value.genericWhereClause?.trimmedDescription ?? "")"
    }
    if let value = declaration.as(InitializerDeclSyntax.self) {
        let parameters = value.signature.parameterClause.parameters.map {
            "\($0.firstName.text):\($0.type.trimmedDescription)"
        }.joined(separator: ",")
        return "initializer:\(value.genericParameterClause?.trimmedDescription ?? "")(\(parameters))\(value.signature.effectSpecifiers?.trimmedDescription ?? "")\(value.genericWhereClause?.trimmedDescription ?? "")"
    }
    return "other:\(declaration.trimmedDescription)"
}

private func sanitize(_ value: String) -> String {
    String(value.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_"
    })
}

private func indent(_ value: String, by spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return value.split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}

private func write(_ source: String, to output: URL) throws {
    do {
        let data = Data(source.utf8)
        if (try? Data(contentsOf: output)) == data {
            return
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output, options: .atomic)
    } catch {
        throw GeneratorError.source(
            .init(path: output.path, line: 1, column: 1),
            "cannot write generated output: \(error.localizedDescription)"
        )
    }
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let scanner = try Scanner(arguments: arguments)
    // Keep advisory cache state private to the work directory. SwiftPM bundles
    // non-Swift plugin outputs as resources, so only the Swift file is declared.
    let cacheURL = arguments.output.appendingPathExtension("cache.json")
    let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(GenerationCache.self, from: $0) }
    let generated = try scanner.render(cached: cached, identity: GeneratorIdentity.current())
    try write(generated.source, to: arguments.output)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let cacheData = try encoder.encode(generated)
    try write(String(decoding: cacheData, as: UTF8.self), to: cacheURL)
} catch let GeneratorError.usage(message) {
    FileHandle.standardError.write(Data("MocksmithGenerator: \(message)\n".utf8))
    exit(2)
} catch let GeneratorError.source(location, message) {
    FileHandle.standardError.write(
        Data("\(location.path):\(location.line):\(location.column): error: \(message)\n".utf8)
    )
    exit(1)
} catch let diagnostic as SourceDiagnostic {
    FileHandle.standardError.write(
        Data("\(diagnostic.location.path):\(diagnostic.location.line):\(diagnostic.location.column): error: \(diagnostic.message)\n".utf8)
    )
    exit(1)
} catch {
    FileHandle.standardError.write(Data("MocksmithGenerator: \(error)\n".utf8))
    exit(1)
}
