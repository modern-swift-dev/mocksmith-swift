#!/usr/bin/env python3
"""Build a fixture package with SwiftPM and check the build plugin's generator invocation.

On macOS the plugin uses the bundled generator through a prebuild command, which
runs on every build. Set MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE=1 (or run on Linux)
to exercise the build-command path instead; that also compiles swift-syntax.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


def main():
    root = Path(__file__).resolve().parent.parent
    build_command = sys.platform != "darwin" or os.environ.get("MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE") == "1"
    scratch = root / ".build"
    scratch.mkdir(exist_ok=True)
    with TemporaryDirectory(prefix="plugin-fixture-test-", dir=scratch) as temporary:
        package = Path(temporary) / "Fixture"
        external = Path(temporary) / "External"
        package.mkdir()
        external.mkdir()

        def write_manifest(unimported_name):
            (package / "Package.swift").write_text(f'''// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "PluginFixture",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: {json.dumps(str(root))}), .package(path: "../External")],
    targets: [
        .target(
            name: "App",
            dependencies: [
                "Library",
                {json.dumps(unimported_name)},
                .product(name: "ExtUsed", package: "External"),
                .product(name: "ExtUnused", package: "External"),
                .product(name: "Mocksmith", package: {json.dumps(root.name)}),
            ],
            plugins: [.plugin(name: "MocksmithBuildPlugin", package: {json.dumps(root.name)})]
        ),
        .target(name: "Library", dependencies: ["Deep"]),
        .target(name: "Deep", dependencies: [.product(name: "ExtDeep", package: "External")]),
        .target(name: {json.dumps(unimported_name)}, path: "Sources/Unimported"),
    ]
)
''')

        def write_source(package, target, imports):
            directory = package / "Sources" / target
            directory.mkdir(parents=True, exist_ok=True)
            lines = [f"import {module}" for module in imports]
            (directory / f"{target}.swift").write_text("\n".join([*lines, f"public func {target.lower()}() {{}}", ""]))

        write_manifest("Unimported")
        write_source(package, "App", ["Library", "ExtUsed"])
        write_source(package, "Library", ["Deep"])
        write_source(package, "Deep", ["ExtDeep"])
        write_source(package, "Unimported", [])
        (external / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "External",
    products: ["ExtUsed", "ExtUnused", "ExtDeep"].map { .library(name: $0, targets: [$0]) },
    targets: [
        .target(name: "ExtUsed", dependencies: ["ExtTransitive", "ExtNotImported"]),
        .target(name: "ExtTransitive"),
        .target(name: "ExtNotImported"),
        .target(name: "ExtUnused"),
        .target(name: "ExtDeep"),
    ]
)
''')
        write_source(external, "ExtUsed", ["ExtTransitive"])
        for target in ("ExtTransitive", "ExtNotImported", "ExtUnused", "ExtDeep"):
            write_source(external, target, [])

        def build(label):
            print(label, flush=True)
            # The generator's private cache is not a declared output, so deleting
            # it is invisible to the build system; only a generator run restores it.
            for cache in package.glob(".build/plugins/outputs/*/App/*/MocksmithBuildPlugin/generation.cache.json"):
                cache.unlink()
            result = subprocess.run(
                ["swift", "build", "--package-path", str(package)],
                cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            if result.returncode:
                raise RuntimeError(f"{label} failed:\n{result.stdout[-16000:]}")
            return generator_arguments().with_name("generation.cache.json").exists()

        def generator_arguments():
            files = list(package.glob(".build/plugins/outputs/*/App/*/MocksmithBuildPlugin/arguments.txt"))
            assert len(files) == 1, files
            return files[0]

        def selected_modules():
            lines = generator_arguments().read_text().split("\n")
            assert lines[lines.index("--target-module") + 1] == "App", lines
            return {lines[index + 1] for index, line in enumerate(lines) if line == "--module"}

        # Every local dependency is passed to the generator. External modules are
        # passed only when imported by a scanned module: the target, local modules
        # it reaches through imports, and external modules already selected.
        local_modules = {"App", "Library", "Deep"}
        assert build("Initial build")
        assert selected_modules() == local_modules | {"Unimported", "ExtUsed", "ExtTransitive", "ExtDeep"}, \
            selected_modules()
        # SwiftPM's native build system (Linux) relinks the generator on the next
        # build, which reruns it regardless of the plugin's inputs.
        build("Settling build")

        # An unchanged response file keeps its timestamp, so it does not
        # invalidate the generator command it is an input of.
        written = generator_arguments().stat().st_mtime_ns
        # A prebuild command runs on every build.
        assert build("Unchanged build") != build_command
        assert generator_arguments().stat().st_mtime_ns == written

        # Renaming a dependency keeps every input file but changes the module
        # arguments, which reach the generator only through the response file.
        write_manifest("Renamed")
        assert build("Renamed dependency")
        assert selected_modules() == local_modules | {"Renamed", "ExtUsed", "ExtTransitive", "ExtDeep"}, \
            selected_modules()

        # Dropping an import deselects the external modules reached only through it.
        write_source(package, "Deep", [])
        if sys.platform != "darwin":
            # SwiftPM's native build system re-invokes build tool plugins only
            # when the file list or manifest changes, not after content edits.
            (package / "Sources/Deep/Added.swift").write_text("")
        assert build("Removed import")
        assert selected_modules() == local_modules | {"Renamed", "ExtUsed", "ExtTransitive"}, selected_modules()

    mode = "build command" if build_command else "prebuild command"
    print(f"Build plugin module selection and response-file checks passed ({mode}).")


if __name__ == "__main__":
    main()
