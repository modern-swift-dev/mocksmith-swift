// swift-tools-version: 6.3

import CompilerPluginSupport
import Foundation
import PackageDescription

#if os(macOS)
    let usePrebuiltGenerator = ProcessInfo.processInfo.environment["MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE"] != "1"
#else
    let usePrebuiltGenerator = false
#endif

let package = Package(
    name: "Mocksmith",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "Mocksmith", targets: ["Mocksmith"]),
        .library(name: "MocksmithCombine", targets: ["MocksmithCombine"]),
        .library(name: "MocksmithTesting", targets: ["MocksmithTesting"]),
        .library(name: "MocksmithXCTest", targets: ["MocksmithXCTest"]),
        .plugin(name: "MocksmithBuildPlugin", targets: ["MocksmithBuildPlugin"])
    ],
    dependencies: [
        .package(path: "Tests/Fixtures/external-protocols"),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin.git",
            exact: "1.5.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        )
    ],
    targets: [
        .target(
            name: "MocksmithGeneration",
            dependencies: [
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
            ]
        ),
        .macro(
            name: "MocksmithMacros",
            dependencies: [
                "MocksmithGeneration",
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
            ]
        ),
        .target(name: "Mocksmith", dependencies: ["MocksmithMacros"]),
        .target(name: "MocksmithCombine", dependencies: ["Mocksmith"]),
        .target(name: "MocksmithTesting", dependencies: ["Mocksmith"]),
        .target(name: "MocksmithXCTest", dependencies: ["Mocksmith"]),
        .target(
            name: "MocksmithInheritanceFixture",
            dependencies: ["Mocksmith"],
            plugins: ["MocksmithBuildPlugin"]
        ),
        .executableTarget(
            name: "MocksmithGenerator",
            dependencies: [
                "MocksmithGeneration",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax")
            ]
        ),
        .plugin(
            name: "MocksmithBuildPlugin",
            capability: .buildTool(),
            dependencies: [usePrebuiltGenerator ? "MocksmithGeneratorPrebuilt" : "MocksmithGenerator"]
        ),
        // Xcode links the testable macro object into test bundles; its renderer must also be linked.
        .testTarget(name: "MocksmithRuntimeTests", dependencies: ["Mocksmith", "MocksmithGeneration"]),
        .testTarget(
            name: "MocksmithCombineTests",
            dependencies: ["Mocksmith", "MocksmithCombine", "MocksmithGeneration"]
        ),
        .testTarget(
            name: "MocksmithMacrosTests",
            dependencies: [
                "MocksmithMacros",
                "MocksmithGeneration",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "MocksmithIntegrationTests",
            dependencies: [
                "Mocksmith",
                "MocksmithTesting",
                "MocksmithXCTest",
                "MocksmithInheritanceFixture",
                .product(name: "ExternalProtocols", package: "external-protocols")
            ],
            plugins: ["MocksmithBuildPlugin"]
        ),
        .testTarget(
            name: "MocksmithSamples",
            dependencies: ["Mocksmith", "MocksmithTesting", "MocksmithXCTest"],
            path: "samples/Tests",
            plugins: ["MocksmithBuildPlugin"]
        )
    ],
    swiftLanguageModes: [.v6]
)

if usePrebuiltGenerator {
    package.targets.append(.binaryTarget(
        name: "MocksmithGeneratorPrebuilt",
        path: "Tools/MocksmithGenerator.artifactbundle"
    ))
}
