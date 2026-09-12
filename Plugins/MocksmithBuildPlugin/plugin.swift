import Foundation
import PackagePlugin

@main struct MocksmithBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let currentModule = target.sourceModule else {
            return []
        }

        let localTargetIDs = Set(context.package.targets.map(\.id))
        let sourceDependencies = target.recursiveTargetDependencies
            .compactMap(\.sourceModule)
        var seenModules = Set<String>()
        let localModules = ([currentModule] + sourceDependencies.filter { localTargetIDs.contains($0.id) })
            .filter { seenModules.insert($0.id).inserted }
        let externalModules = sourceDependencies
            .filter { !localTargetIDs.contains($0.id) }
            .sorted { ($0.moduleName, $0.id) < ($1.moduleName, $1.id) }
        let localModulesByName = Dictionary(grouping: localModules, by: \.moduleName)
        let externalModulesByName = Dictionary(grouping: externalModules, by: \.moduleName)

        var importScanner = ImportScanner(cacheURL: context.pluginWorkDirectoryURL.appending(component: "imports.cache.json"))
        var selectedModules = Dictionary(uniqueKeysWithValues: localModules.map { ($0.id, $0) })
        var scannedModules = Set<String>()
        var modulesToScan = [currentModule]
        while let module = modulesToScan.popLast() {
            guard scannedModules.insert(module.id).inserted else {
                continue
            }
            for importedModule in try importScanner.importedModuleNames(in: swiftSourceFiles(for: module)).sorted() {
                modulesToScan += localModulesByName[importedModule] ?? []
                guard let candidates = externalModulesByName[importedModule] else {
                    continue
                }
                for candidate in candidates where selectedModules[candidate.id] == nil {
                    selectedModules[candidate.id] = candidate
                    modulesToScan.append(candidate)
                }
            }
        }
        try importScanner.save()
        let modules = selectedModules.values.sorted { ($0.moduleName, $0.id) < ($1.moduleName, $1.id) }

        let output = context.pluginWorkDirectoryURL.appending(component: "Mocksmith.generated.swift")
        var arguments = ["--output", output.path, "--target-module", currentModule.moduleName]
        var inputFiles = [URL]()
        var seenFiles = Set<URL>()

        for module in modules {
            let files = swiftSourceFiles(for: module)
                .filter { seenFiles.insert($0).inserted }
            guard !files.isEmpty else {
                continue
            }
            arguments += ["--module", module.moduleName]
            arguments += files.map(\.path)
            inputFiles += files
        }

        guard !inputFiles.isEmpty else {
            return []
        }
        return [.buildCommand(
            displayName: "Generating Mocksmith mocks for \(target.name)",
            executable: try context.tool(named: "MocksmithGenerator").url,
            arguments: arguments,
            inputFiles: inputFiles,
            outputFiles: [output]
        )]
    }

    private func swiftSourceFiles(for module: SourceModuleTarget) -> [URL] {
        module.sourceFiles
            .filter { $0.type == .source && $0.url.pathExtension == "swift" }
            .map(\.url)
            .sorted { $0.path < $1.path }
    }
}
