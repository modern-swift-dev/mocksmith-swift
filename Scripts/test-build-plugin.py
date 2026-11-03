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
        package = Path(temporary)

        def write_manifest(library_name):
            (package / "Package.swift").write_text(f'''// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "PluginFixture",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: {json.dumps(str(root))})],
    targets: [
        .target(
            name: "App",
            dependencies: [
                {json.dumps(library_name)},
                .product(name: "Mocksmith", package: {json.dumps(root.name)}),
            ],
            plugins: [.plugin(name: "MocksmithBuildPlugin", package: {json.dumps(root.name)})]
        ),
        .target(name: {json.dumps(library_name)}, path: "Sources/Library"),
    ]
)
''')

        def write_source(target, text):
            directory = package / "Sources" / target
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"{target}.swift").write_text(text)

        write_manifest("Library")
        write_source("App", "func app() -> Int { 1 }\n")
        write_source("Library", "public func library() -> Int { 1 }\n")

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
            return {lines[index + 1] for index, line in enumerate(lines) if line == "--module"}

        assert build("Initial build")
        assert selected_modules() == {"App", "Library"}, selected_modules()
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
        assert selected_modules() == {"App", "Renamed"}, selected_modules()

    mode = "build command" if build_command else "prebuild command"
    print(f"Build plugin response-file checks passed ({mode}).")


if __name__ == "__main__":
    main()
