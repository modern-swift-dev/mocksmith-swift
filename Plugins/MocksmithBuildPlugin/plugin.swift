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

        let generatedDirectory = context.pluginWorkDirectoryURL.appending(component: "GeneratedSources")
        let output = generatedDirectory.appending(component: "Mocksmith.generated.swift")
        let cache = context.pluginWorkDirectoryURL.appending(component: "generation.cache.json")
        var arguments = ["--output", output.path, "--cache", cache.path, "--target-module", currentModule.moduleName]
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
        let executable = try context.tool(named: "MocksmithGenerator").url
        #if os(macOS)
            if ProcessInfo.processInfo.environment["MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE"] != "1" {
                // Xcode hashes per-target build commands in unordered dictionary order.
                // Prebuild results avoid that unstable cache key; the generator's content
                // cache preserves unchanged source timestamps across invocations.
                return [.prebuildCommand(
                    displayName: "Generating Mocksmith mocks for \(target.name)",
                    executable: executable,
                    arguments: arguments,
                    outputFilesDirectory: generatedDirectory
                )]
            }
        #endif
        return [.buildCommand(
            displayName: "Generating Mocksmith mocks for \(target.name)",
            executable: executable,
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
