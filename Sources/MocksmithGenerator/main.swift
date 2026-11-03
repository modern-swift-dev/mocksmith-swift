import Foundation
import MocksmithGeneration
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion

private let markerOrder = ["AnyObject", "Sendable", "Actor", "~Copyable", "NSObjectProtocol"]
private let markerNames = Set(markerOrder)
/// Reports each parsed source on standard error, so tests can prove that a
/// cache hit skipped parsing.
private let traceParsing = ProcessInfo.processInfo.environment["MOCKSMITH_GENERATOR_TRACE_PARSING"] == "1"

private struct Arguments {
    let output: URL
    let cache: URL
    let targetModule: String
    let modules: [ModuleInput]

    init(_ arguments: [String]) throws {
        var values = arguments
        if values.count == 1, values[0].hasPrefix("@") {
            let path = String(values[0].dropFirst())
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw GeneratorError.usage("cannot read response file '\(path)'")
            }
            values = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        var output: URL?
        var cache: URL?
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
                case "--cache":
                    index += 1
                    guard index < values.count else {
                        throw GeneratorError.usage("missing value after --cache")
                    }
                    cache = URL(fileURLWithPath: values[index])
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
        self.cache = cache ?? output.appendingPathExtension("cache.json")
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
    let snapshot: SourceSnapshot?
    let usesDependencySources: Bool?
    let source: String
}

private struct SourceInput {
    let module: String
    let path: String
    let source: String
    /// Computed from the bytes read from disk, so each file is read only once.
    let digest: String

    var fingerprint: SourceFingerprint {
        SourceFingerprint(module: module, path: path, digest: digest)
    }
}

/// What the cache records about a source file: its content digest rather than
/// its text, so the cache stays small while still detecting any edit.
private struct SourceFingerprint: Codable, Equatable {
    let module: String
    let path: String
    let digest: String
}

private struct SourceSnapshot: Codable, Equatable {
    let modules: [String]
    let sources: [SourceFingerprint]
    /// The texts behind `sources`, kept in memory for parsing but never cached.
    let contents: [SourceInput]

    private enum CodingKeys: String, CodingKey {
        case modules
        case sources
    }

    init(targetOf arguments: Arguments) throws {
        self.init(
            modules: Set(arguments.modules.map(\.name)).sorted(),
            contents: try Self.read(arguments.modules.filter { $0.name == arguments.targetModule })
        )
    }

    init(modules: [String], contents: [SourceInput]) {
        self.modules = modules
        self.contents = contents
        sources = contents.map(\.fingerprint)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modules = try container.decode([String].self, forKey: .modules)
        sources = try container.decode([SourceFingerprint].self, forKey: .sources)
        contents = []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modules == rhs.modules && lhs.sources == rhs.sources
    }

    func includingDependencies(from arguments: Arguments) throws -> Self {
        let dependencies = try Self.read(arguments.modules.filter { $0.name != arguments.targetModule })
        return Self(modules: modules, contents: (contents + dependencies).sorted {
            ($0.module, $0.path) < ($1.module, $1.path)
        })
    }

    private static func read(_ modules: [ModuleInput]) throws -> [SourceInput] {
        var sources: [SourceInput] = []
        for module in modules.sorted(by: { $0.name < $1.name }) {
            for path in module.paths.sorted() {
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: path))
                } catch {
                    throw GeneratorError.source(
                        .init(path: path, line: 1, column: 1),
                        "cannot read source: \(error.localizedDescription)"
                    )
                }
                // Read every input in the relevant modules: a previously irrelevant
                // file may gain a declaration, even with unchanged size and mtime.
                let isRelevant = data.withUnsafeBytes { bytes in
                    ["Mockable", "protocol", "typealias", "@_exported"].contains { containsText($0, in: bytes) }
                }
                guard isRelevant else {
                    continue
                }
                guard let source = String(data: data, encoding: .utf8) else {
                    throw GeneratorError.source(
                        .init(path: path, line: 1, column: 1),
                        "cannot read source: the file is not valid UTF-8"
                    )
                }
                sources.append(SourceInput(module: module.name, path: path, source: source, digest: SHA256.hexDigest(of: data)))
            }
        }
        return sources
    }
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
    /// Every module imported at top level, including inside `#if` clauses,
    /// whose conditions the generator cannot evaluate.
    let importedModules: Set<String>
    /// The imported modules this file re-exports with `@_exported import`.
    let exportedModules: Set<String>
    let imports: CodeBlockItemListSyntax
    private let locations: LazySourceLocations

    init(module: String, path: String, tree: SourceFileSyntax, imports: CodeBlockItemListSyntax) {
        self.module = module
        self.path = path
        self.tree = tree
        importedModules = importedModuleNames(in: imports, exportedOnly: false)
        exportedModules = importedModuleNames(in: imports, exportedOnly: true)
        self.imports = imports
        locations = LazySourceLocations(path: path, tree: tree)
    }

    func location(of node: some SyntaxProtocol) -> SourceDiagnostic.Location {
        let location = locations.converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return .init(path: path, line: location.line, column: location.column)
    }
}

/// Builds the line table for a file on first use and shares it across every
/// diagnostic reported against that file.
private final class LazySourceLocations {
    private(set) lazy var converter = SourceLocationConverter(fileName: path, tree: tree)
    private let path: String
    private let tree: SourceFileSyntax

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        self.tree = tree
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

/// A protocol or alias with everything it inherits, parents first.
private struct InheritanceClosure {
    private(set) var protocols: [ProtocolRecord] = []
    private(set) var aliases: [AliasRecord] = []
    private(set) var markers = Set<String>()
    private var protocolIDs = Set<DeclarationID>()
    private var aliasIDs = Set<DeclarationID>()

    init() {}

    init(marker: String) {
        markers = [marker]
    }

    /// Keeps the first occurrence of each declaration, matching a depth-first
    /// walk that skips already visited declarations.
    mutating func append(_ other: Self) {
        for record in other.protocols where protocolIDs.insert(record.id).inserted {
            protocols.append(record)
        }
        for record in other.aliases where aliasIDs.insert(record.id).inserted {
            aliases.append(record)
        }
        markers.formUnion(other.markers)
    }

    mutating func append(_ record: ProtocolRecord) {
        if protocolIDs.insert(record.id).inserted {
            protocols.append(record)
        }
    }

    mutating func append(_ record: AliasRecord) {
        if aliasIDs.insert(record.id).inserted {
            aliases.append(record)
        }
    }
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
    private struct SourceKey: Hashable {
        let module: String
        let path: String
    }

    private let targetModule: String
    private var units: [SourceUnit] = []
    private let availableSourceModules: Set<String>
    /// Whether any root mock inherits requirements, which is the only case that
    /// needs sources beyond the target module's own `@Mockable` candidates.
    let usesDependencySources: Bool
    private var protocols: [DeclarationID: [ProtocolRecord]] = [:]
    private var aliases: [DeclarationID: [AliasRecord]] = [:]
    /// Sources not parsed as candidates, by module; resolution parses them on demand.
    private var remainingSources: [String: [SourceInput]] = [:]
    /// Unparsed sources by module and by a name they may declare.
    private var declarationIndex: [String: [String: [SourceInput]]] = [:]
    private var loadedSources = Set<SourceKey>()
    private var reexports: [String: Set<String>] = [:]
    private var closures: [ResolvedDeclaration: InheritanceClosure] = [:]
    private var resolving = Set<ResolvedDeclaration>()
    private var memberKeys: [SyntaxIdentifier: String] = [:]
    private var memberTexts: [SyntaxIdentifier: String] = [:]
    private var importTexts: [Int: [String]] = [:]

    /// Parses only the target module's candidates. Call `loadRemainingSources`
    /// before rendering when `usesDependencySources` is true.
    init(targetModule: String, snapshot: SourceSnapshot) throws {
        self.targetModule = targetModule
        availableSourceModules = Set(snapshot.modules)

        let targetInputs = snapshot.contents.filter { $0.module == targetModule }
        let targetCandidates = Self.parse(targetInputs, onlyMockableCandidates: true)
        try validateBuildPluginDeclarations(targetCandidates)
        usesDependencySources = targetCandidates.contains(where: requiresDependencySources)
        register(targetCandidates)
    }

    /// Makes every source not already loaded as a candidate available to
    /// inherited-protocol resolution, which parses only the files it needs.
    func loadRemainingSources(from snapshot: SourceSnapshot) {
        for input in snapshot.contents where !loadedSources.contains(SourceKey(module: input.module, path: input.path)) {
            remainingSources[input.module, default: []].append(input)
        }
    }

    private func load(_ sources: [SourceInput]) {
        register(Self.parse(sources.filter { !loadedSources.contains(SourceKey(module: $0.module, path: $0.path)) }))
    }

    /// Parses the sources of `module` that may declare `name`. The module's
    /// sources are indexed lexically on first use; files whose declarations
    /// cannot be read that way are parsed immediately.
    private func loadDeclarations(named name: String, in module: String) {
        if declarationIndex[module] == nil {
            var index: [String: [SourceInput]] = [:]
            var unindexed: [SourceInput] = []
            for input in remainingSources[module] ?? [] where !loadedSources.contains(SourceKey(module: input.module, path: input.path)) {
                guard let names = declaredNames(in: input.source) else {
                    unindexed.append(input)
                    continue
                }
                for name in names {
                    index[name, default: []].append(input)
                }
            }
            declarationIndex[module] = index
            load(unindexed)
        }
        load(declarationIndex[module]?.removeValue(forKey: name) ?? [])
    }

    /// The modules that `module` makes visible to its importers through
    /// `@_exported import`, transitively.
    private func reexportedModules(of module: String) -> Set<String> {
        var result = Set<String>()
        var pending = [module]
        while let next = pending.popLast() {
            for exported in directlyReexportedModules(of: next) where result.insert(exported).inserted {
                pending.append(exported)
            }
        }
        return result
    }

    private func directlyReexportedModules(of module: String) -> Set<String> {
        if let modules = reexports[module] {
            return modules
        }
        load((remainingSources[module] ?? []).filter { containsText("@_exported", in: $0.source) })
        let modules = Set(units.filter { $0.module == module }.flatMap(\.exportedModules))
        reexports[module] = modules
        return modules
    }

    private func register(_ parsed: [SourceUnit]) {
        for unit in parsed {
            let unitIndex = units.count
            units.append(unit)
            loadedSources.insert(SourceKey(module: unit.module, path: unit.path))
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
        _ sources: [SourceInput],
        onlyMockableCandidates: Bool = false
    ) -> [SourceUnit] {
        var units: [SourceUnit] = []
        for input in sources {
            if onlyMockableCandidates {
                guard containsText("Mockable", in: input.source) else {
                    continue
                }
            } else if !["protocol", "typealias", "@_exported"].contains(where: { containsText($0, in: input.source) }) {
                continue
            }
            if traceParsing {
                FileHandle.standardError.write(Data("MocksmithGenerator: parsed \(input.path)\n".utf8))
            }
            let tree = Parser.parse(source: input.source)
            units.append(
                SourceUnit(module: input.module, path: input.path, tree: tree, imports: importStatements(in: tree.statements))
            )
        }
        return units
    }

    func render(cached: GenerationCache?, identity: GeneratorIdentity?, snapshot: SourceSnapshot) throws -> GenerationCache {
        let snapshot = usesDependencySources ? snapshot : SourceSnapshot(
            modules: snapshot.modules,
            contents: snapshot.contents.filter { $0.module == targetModule }
        )
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
        var importLines = Set(["import Mocksmith"])
        for root in roots {
            loadDeclarations(named: root.id.name, in: root.id.module)
            if protocols[root.id]?.count != 1 {
                throw sourceError(at: root, "ambiguous top-level protocol '\(root.id.name)' in module '\(root.id.module)'")
            }
            let access = try AccessLevel.read(from: root, units: units)
            let flattened = try flatten(root)
            preparedMocks.append(try prepareMock(root: root, access: access, flattened: flattened))

            let contributingUnits = Set(flattened.records.map(\.unit) + flattened.aliases.map(\.unit))
            for unitIndex in contributingUnits {
                importLines.formUnion(importTexts(of: unitIndex))
            }
        }

        let input = GenerationInput(
            targetModule: targetModule,
            mocks: preparedMocks.map(\.input),
            imports: importLines.sorted()
        )
        if let identity, let cached, cached.generator == identity, cached.input == input {
            return GenerationCache(
                generator: identity, input: input, snapshot: snapshot,
                usesDependencySources: usesDependencySources, source: cached.source
            )
        }
        let sections = preparedMocks.map { $0.generator.render() }
        let imports = input.imports.joined(separator: "\n")
        let body = sections.isEmpty ? "" : "\n\n" + sections.joined(separator: "\n\n")
        let source = "// Generated by MocksmithGenerator. Do not edit.\n\(imports)\(body)\n"
        return GenerationCache(
            generator: identity, input: input, snapshot: snapshot,
            usesDependencySources: usesDependencySources, source: source
        )
    }

    /// The import statements a mock needs for declarations from this unit.
    private func importTexts(of unitIndex: Int) -> [String] {
        if let texts = importTexts[unitIndex] {
            return texts
        }
        let unit = units[unitIndex]
        var texts = unit.module == targetModule ? [] : ["import \(unit.module)"]
        texts += importStatements(in: unit.imports, excluding: targetModule).map(\.trimmedDescription)
        importTexts[unitIndex] = texts
        return texts
    }

    private func flatten(_ root: ProtocolRecord) throws -> FlattenedProtocol {
        let closure = try inheritanceClosure(of: root)
        let orderedProtocols = closure.protocols

        var memberOrder: [String] = []
        var membersByKey: [String: MemberBlockItemSyntax] = [:]
        var attributes: [AttributeSyntax] = []
        var seenAttributes = Set<String>()
        var whereRequirements: [String] = []
        var seenRequirements = Set<String>()

        for record in orderedProtocols {
            for member in record.declaration.memberBlock.members {
                let key = cachedMemberKey(member)
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
            aliases: closure.aliases,
            members: memberOrder.compactMap { membersByKey[$0] },
            markers: closure.markers,
            attributes: attributes,
            whereRequirements: whereRequirements
        )
    }

    /// Shared parents are resolved once per run rather than once per mock.
    private func inheritanceClosure(of record: ProtocolRecord) throws -> InheritanceClosure {
        let node = ResolvedDeclaration.protocolDecl(record.id)
        if let closure = closures[node] {
            return closure
        }
        guard resolving.insert(node).inserted else {
            throw sourceError(at: record, "protocol inheritance cycle involving '\(record.id)'")
        }
        defer { resolving.remove(node) }

        var closure = InheritanceClosure()
        for inherited in record.declaration.inheritanceClause?.inheritedTypes ?? [] {
            for reference in try references(in: inherited.type, unit: record.unit) {
                try closure.append(inheritanceClosure(of: reference, from: record.unit))
            }
        }
        closure.append(record)
        closures[node] = closure
        return closure
    }

    private func inheritanceClosure(of record: AliasRecord) throws -> InheritanceClosure {
        let node = ResolvedDeclaration.alias(record.id)
        if let closure = closures[node] {
            return closure
        }
        if record.declaration.genericParameterClause != nil || record.declaration.genericWhereClause != nil {
            throw sourceError(at: record, "generic protocol-composition alias '\(record.id)' is not supported")
        }
        guard resolving.insert(node).inserted else {
            throw sourceError(at: record, "protocol-composition alias cycle involving '\(record.id)'")
        }
        defer { resolving.remove(node) }

        var closure = InheritanceClosure()
        for reference in try references(in: record.declaration.initializer.value, unit: record.unit) {
            try closure.append(inheritanceClosure(of: reference, from: record.unit))
        }
        closure.append(record)
        closures[node] = closure
        return closure
    }

    private func inheritanceClosure(of reference: TypeReference, from unit: Int) throws -> InheritanceClosure {
        if markerNames.contains(reference.name) {
            return InheritanceClosure(marker: reference.name)
        }
        if reference.hasGenericArguments {
            throw GeneratorError.source(
                units[unit].location(of: units[unit].tree),
                "generic inherited protocol references are not supported: '\(reference.name)'"
            )
        }
        switch try resolve(reference, from: unit) {
            case let .protocolDecl(id):
                return try inheritanceClosure(of: uniqueProtocol(id, referencedFrom: unit))
            case let .alias(id):
                return try inheritanceClosure(of: uniqueAlias(id, referencedFrom: unit))
        }
    }

    private func cachedMemberKey(_ member: MemberBlockItemSyntax) -> String {
        if let key = memberKeys[member.id] {
            return key
        }
        let key = memberKey(member.decl)
        memberKeys[member.id] = key
        return key
    }

    private func resolve(_ reference: TypeReference, from unit: Int) throws -> ResolvedDeclaration {
        if let module = reference.module {
            guard availableSourceModules.contains(module) else {
                throw GeneratorError.source(
                    units[unit].location(of: units[unit].tree),
                    "inherited protocol '\(module).\(reference.name)' has no readable source available; binary, SDK, and precompiled modules are unsupported"
                )
            }
            loadDeclarations(named: reference.name, in: module)
            return try resolvedDeclaration(.init(module: module, name: reference.name), referencedFrom: unit)
        }

        let local = DeclarationID(module: units[unit].module, name: reference.name)
        loadDeclarations(named: reference.name, in: local.module)
        if protocols[local] != nil || aliases[local] != nil {
            return try resolvedDeclaration(local, referencedFrom: unit)
        }

        let directlyImported = units[unit].importedModules.filter(availableSourceModules.contains)
        let importedModules = directlyImported
            .union(directlyImported.flatMap(reexportedModules(of:)))
            .filter(availableSourceModules.contains)
        for module in importedModules {
            loadDeclarations(named: reference.name, in: module)
        }
        let candidates = importedModules
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
            .map { member in
                if let text = memberTexts[member.id] {
                    return text
                }
                let text = indent(member.decl.trimmedDescription, by: 4)
                memberTexts[member.id] = text
                return text
            }
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

private func importedModuleNames(in statements: CodeBlockItemListSyntax, exportedOnly: Bool) -> Set<String> {
    var names = Set<String>()
    for item in statements {
        if let declaration = item.item.as(ImportDeclSyntax.self) {
            if !exportedOnly || hasAttribute(named: "_exported", in: declaration.attributes),
               let name = declaration.path.first?.name.text {
                names.insert(name)
            }
        } else if let conditional = item.item.as(IfConfigDeclSyntax.self) {
            for clause in conditional.clauses {
                if let nested = clause.elements?.as(CodeBlockItemListSyntax.self) {
                    names.formUnion(importedModuleNames(in: nested, exportedOnly: exportedOnly))
                }
            }
        }
    }
    return names
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

    /// Protocols cannot be declared in function, accessor, or closure bodies,
    /// so skip walking them.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
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

/// Names that follow a `protocol` or `typealias` keyword anywhere in `source`,
/// a superset of its top-level protocol and alias declarations found without
/// parsing. Returns nil when a comment follows a keyword, since the declared
/// name cannot then be read lexically.
private func declaredNames(in source: String) -> Set<String>? {
    var source = source
    return source.withUTF8 { bytes -> Set<String>? in
        var names = Set<String>()
        for keyword in ["protocol", "typealias"] {
            let keyword = Array(keyword.utf8)
            var index = 0
            while let start = firstIndex(of: keyword, in: bytes, from: index) {
                index = start + keyword.count
                if start > 0, isIdentifierByte(bytes[start - 1]) {
                    continue
                }
                var position = index
                while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) {
                    position += 1
                }
                guard position < bytes.count else {
                    continue
                }
                if bytes[position] == UInt8(ascii: "/") {
                    return nil
                }
                // Other text right after the keyword makes it part of a longer token.
                guard position > index else {
                    continue
                }
                let isEscaped = bytes[position] == UInt8(ascii: "`")
                let nameStart = isEscaped ? position + 1 : position
                var nameEnd = nameStart
                while nameEnd < bytes.count, isIdentifierByte(bytes[nameEnd]) {
                    nameEnd += 1
                }
                guard nameEnd > nameStart else {
                    continue
                }
                // Identifier runs start and end next to ASCII bytes, so they always decode.
                guard let name = String(bytes: UnsafeBufferPointer(rebasing: bytes[nameStart ..< nameEnd]), encoding: .utf8) else {
                    return nil
                }
                names.insert(name)
                if isEscaped {
                    names.insert("`\(name)`")
                }
            }
        }
        return names
    }
}

/// Byte-wise substring search; `String.contains` compares `Character`s, which
/// costs far more on whole source files.
private func containsText(_ needle: String, in source: String) -> Bool {
    var source = source
    return source.withUTF8 { containsText(needle, in: UnsafeRawBufferPointer($0)) }
}

private func containsText(_ needle: String, in bytes: UnsafeRawBufferPointer) -> Bool {
    var needle = needle
    return needle.withUTF8 { needle in
        guard let base = bytes.baseAddress, let needleBase = needle.baseAddress else {
            return needle.isEmpty
        }
        return memmem(base, bytes.count, needleBase, needle.count) != nil
    }
}

private func isIdentifierByte(_ byte: UInt8) -> Bool {
    byte >= 0x80 || byte == UInt8(ascii: "_")
        || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
}

private func firstIndex(of needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
    guard start < bytes.count, let base = bytes.baseAddress else {
        return nil
    }
    let found = needle.withUnsafeBufferPointer { needle -> UnsafeMutableRawPointer? in
        guard let needleBase = needle.baseAddress else {
            return nil
        }
        return memmem(base + start, bytes.count - start, needleBase, needle.count)
    }
    return found.map { UnsafeRawPointer(base).distance(to: UnsafeRawPointer($0)) }
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

private func write(_ data: Data, to output: URL) throws {
    do {
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
    // Prebuild output directories are scanned as target inputs. The plugin keeps
    // this advisory cache outside that directory so it cannot become a resource.
    let cacheURL = arguments.cache
    let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(GenerationCache.self, from: $0) }
    let identity = GeneratorIdentity.current()
    let targetSnapshot = try SourceSnapshot(targetOf: arguments)
    func cacheMatches(_ snapshot: SourceSnapshot) -> Bool {
        identity != nil && cached?.generator == identity
            && cached?.input.targetModule == arguments.targetModule
            && cached?.usesDependencySources != nil && cached?.snapshot == snapshot
    }
    // When the previous run needed dependency sources, an identical snapshot of
    // them proves the target is unchanged too, so compare it before parsing.
    let fullSnapshot = cached?.usesDependencySources == true
        ? try targetSnapshot.includingDependencies(from: arguments)
        : nil
    let generated: GenerationCache
    let cacheHit: Bool
    if let cached, cached.usesDependencySources == false, cacheMatches(targetSnapshot) {
        generated = cached
        cacheHit = true
    } else if let cached, let fullSnapshot, cacheMatches(fullSnapshot) {
        generated = cached
        cacheHit = true
    } else {
        // Parse the target's candidates first: direct mocks never need another
        // module's sources, so those files are read only when inheritance demands.
        let scanner = try Scanner(targetModule: arguments.targetModule, snapshot: targetSnapshot)
        if scanner.usesDependencySources {
            let snapshot = try fullSnapshot ?? targetSnapshot.includingDependencies(from: arguments)
            if let cached, cacheMatches(snapshot) {
                generated = cached
                cacheHit = true
            } else {
                scanner.loadRemainingSources(from: snapshot)
                generated = try scanner.render(cached: cached, identity: identity, snapshot: snapshot)
                cacheHit = false
            }
        } else {
            generated = try scanner.render(cached: cached, identity: identity, snapshot: targetSnapshot)
            cacheHit = false
        }
    }
    try write(Data(generated.source.utf8), to: arguments.output)
    if !cacheHit {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cacheData = try encoder.encode(generated)
        try write(cacheData, to: cacheURL)
    }
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
