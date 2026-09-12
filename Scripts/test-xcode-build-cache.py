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
    platforms: [.macOS(.v13)],
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

        build("Initial build")
        initial_keys = project_cache_keys()
        assert initial_keys, "Fixture PIF cache was not created"
        generated = list(derived_data.rglob("Mocksmith.generated.swift"))
        assert len(generated) == 2, generated
        timestamps = {item: item.stat().st_mtime_ns for item in generated}
        for item in generated:
            assert item.parent.name == "GeneratedSources"
            assert list(item.parent.iterdir()) == [item], "Private cache leaked into build outputs"
        for attempt in range(3):
            build(f"Unchanged build {attempt + 1}")
            assert project_cache_keys() == initial_keys, "Unchanged plugin results invalidated the PIF cache"
            assert all(item.stat().st_mtime_ns == timestamps[item] for item in generated)

        service = package / "Sources/First/Service.swift"
        service.write_text(service.read_text().replace("-> Int", "-> String"))
        build("Protocol change")
        first = next(item for item in generated if "/First/" in str(item))
        second = next(item for item in generated if "/Second/" in str(item))
        assert "func value() -> String" in first.read_text()
        assert first.stat().st_mtime_ns != timestamps[first]
        assert second.stat().st_mtime_ns == timestamps[second]

        added = package / "Sources/First/Added.swift"
        added.write_text("import Mocksmith\n@Mockable protocol Added {}\n")
        build("New protocol file")
        assert "class AddedMock:" in first.read_text()
        added.unlink()
        build("Removed protocol file")
        assert "AddedMock" not in first.read_text()

    print("Xcode cache reuse, isolated cache outputs, and protocol edit/add/remove checks passed.")


if __name__ == "__main__":
    main()
