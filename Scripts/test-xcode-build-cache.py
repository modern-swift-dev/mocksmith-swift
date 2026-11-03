#!/usr/bin/env python3
"""Exercise Xcode cache reuse and automatic mock regeneration across two targets."""

import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


def main():
    root = Path(__file__).resolve().parent.parent
    scratch = root / ".build"
    scratch.mkdir(exist_ok=True)
    with TemporaryDirectory(prefix="xcode-cache-test-", dir=scratch) as temporary:
        directory = Path(temporary)
        package = directory / "Fixture"
        package.mkdir()
        (package / "Package.swift").write_text(f'''// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "MocksmithCacheFixture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Fixture", targets: ["First", "Second"])],
    dependencies: [.package(path: {json.dumps(str(root))})],
    targets: ["First", "Second"].map {{ name in
        .target(
            name: name,
            dependencies: [.product(name: "Mocksmith", package: "mocksmith-swift")],
            plugins: [.plugin(name: "MocksmithBuildPlugin", package: "mocksmith-swift")]
        )
    }}
)
''')
        for name in ("First", "Second"):
            sources = package / "Sources" / name
            sources.mkdir(parents=True)
            (sources / "Service.swift").write_text('''import Mocksmith
@Mockable protocol Service { func value() -> Int }
func useGeneratedMock() -> ServiceMock { ServiceMock() }
''')
        (package / "Sources/First/Other.swift").write_text('''import Mocksmith
@Mockable protocol Other { func other() -> Int }
func useOtherMock() -> OtherMock { OtherMock() }
''')
        workspace = directory / "CacheFixture.xcworkspace"
        workspace.mkdir()
        (workspace / "contents.xcworkspacedata").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<Workspace version="1.0"><FileRef location="group:Fixture"/></Workspace>'
        )
        derived_data = directory / "DerivedData"
        command = [
            "xcodebuild", "-workspace", str(workspace), "-scheme", "Fixture",
            "-destination", "platform=macOS", "-derivedDataPath", str(derived_data),
            "-skipPackageUpdates", "build",
        ]

        def build(label):
            print(label, flush=True)
            result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"{label} failed:\n{result.stdout[-16000:]}")

        def project_cache_keys():
            cache = derived_data / "Build/Intermediates.noindex/XCBuildData/PIFCache/project"
            return {
                item.name for item in cache.iterdir()
                if json.loads(item.read_text()).get("projectName") == "MocksmithCacheFixture"
            }

        def generated_files():
            """Maps each generated file to its timestamp."""
            return {item: item.stat().st_mtime_ns for item in derived_data.rglob("*.generated.swift")}

        def generated_file(target, source):
            return next(item for item in generated_files() if f"/{target}/" in str(item) and item.name.startswith(f"{source}."))

        build("Initial build")
        initial_keys = project_cache_keys()
        assert initial_keys, "Fixture PIF cache was not created"
        timestamps = generated_files()
        assert len(timestamps) == 3, timestamps
        for directory in {item.parent for item in timestamps}:
            assert directory.name == "GeneratedSources"
            assert all(item.name.endswith(".generated.swift") for item in directory.iterdir()), \
                "Private cache leaked into build outputs"
        for attempt in range(3):
            build(f"Unchanged build {attempt + 1}")
            assert project_cache_keys() == initial_keys, "Unchanged plugin results invalidated the PIF cache"
            assert generated_files() == timestamps

        # Each source has its own generated file: editing one protocol rewrites
        # only that file, leaving the target's other mocks untouched.
        first = generated_file("First", "Service")
        other = generated_file("First", "Other")
        second = generated_file("Second", "Service")
        other_source = other.read_bytes()
        service = package / "Sources/First/Service.swift"
        service.write_text(service.read_text().replace("-> Int", "-> String"))
        build("Protocol change")
        assert "func value() -> String" in first.read_text()
        assert first.stat().st_mtime_ns != timestamps[first]
        assert other.read_bytes() == other_source
        assert other.stat().st_mtime_ns == timestamps[other]
        assert second.stat().st_mtime_ns == timestamps[second]

        added = package / "Sources/First/Added.swift"
        added.write_text("import Mocksmith\n@Mockable protocol Added {}\n")
        build("New protocol file")
        added_output = generated_file("First", "Added")
        assert "class AddedMock:" in added_output.read_text()
        added.unlink()
        build("Removed protocol file")
        assert not added_output.exists()
        assert not any("AddedMock" in item.read_text() for item in generated_files())

    print("Xcode cache reuse, isolated cache outputs, per-file outputs, and protocol edit/add/remove checks passed.")


if __name__ == "__main__":
    main()
