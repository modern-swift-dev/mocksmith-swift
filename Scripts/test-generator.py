#!/usr/bin/env python3
"""Check generation and incremental output stability using a built generator.

Run after `swift build --product MocksmithGenerator`, or pass its executable path.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("generator", nargs="?", type=Path)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if arguments.generator is None:
        binary_path = Path(subprocess.check_output(
            ["swift", "build", "--show-bin-path"], cwd=root, text=True
        ).strip())
        generator = binary_path / "MocksmithGenerator"
    else:
        generator = arguments.generator.resolve()
    if not generator.is_file():
        raise FileNotFoundError(generator)

    with TemporaryDirectory(prefix="mocksmith-generator-tests-") as directory:
        directory = Path(directory)
        declarations = directory / "Services.swift"
        unrelated = directory / "Unrelated.swift"
        output = directory / "Generated.swift"
        cache = directory / "Generated.swift.cache.json"
        declarations.write_text("""import Mocksmith
@Mockable(.buildPlugin) protocol FastService {
    func value() -> Int
}
@Mockable(.macro) protocol MacroService {}
@Mockable protocol DefaultService {}
protocol Parent {
    func inherited() -> String
}
@Mockable protocol Child: Parent {}
""")
        unrelated.write_text("func unrelated() -> Int { 1 }\n")
        command = [
            str(generator), "--output", str(output),
            "--target-module", "Fixture", "--module", "Fixture",
            str(declarations), str(unrelated),
        ]

        def generate():
            subprocess.run(command, cwd=root, check=True)
            return output.read_text()

        generated = generate()
        assert "class FastServiceMock:" in generated
        assert "class ChildMock:" in generated
        assert "func inherited() -> String" in generated
        assert "MacroServiceMock" not in generated
        assert "DefaultServiceMock" in generated
        assert "@_MocksmithResolved" not in generated
        cached = cache.read_bytes()

        # A fixed timestamp detects rewrites without timing-dependent sleeps.
        os.utime(output, ns=(1_000_000_000, 1_000_000_000))
        os.utime(cache, ns=(1_000_000_000, 1_000_000_000))
        unchanged_mtime = output.stat().st_mtime_ns
        unchanged_cache_mtime = cache.stat().st_mtime_ns
        assert generate() == generated
        assert output.stat().st_mtime_ns == unchanged_mtime
        assert cache.read_bytes() == cached
        assert cache.stat().st_mtime_ns == unchanged_cache_mtime

        unrelated.write_text("func unrelated() -> Int { 2 }\n")
        assert generate() == generated
        assert output.stat().st_mtime_ns == unchanged_mtime
        assert cache.read_bytes() == cached
        assert cache.stat().st_mtime_ns == unchanged_cache_mtime

        declarations.write_text(declarations.read_text().replace(
            "func value() -> Int", "func value() -> String"
        ))
        updated = generate()
        assert updated != generated
        assert "func value() -> String" in updated
        assert output.stat().st_mtime_ns != unchanged_mtime
        assert cache.read_bytes() != cached

        # Imports and access affect generated source even without a member edit.
        for old, new in [
            ("import Mocksmith", "import Mocksmith\nimport Foundation"),
            ("protocol FastService", "public protocol FastService"),
        ]:
            cached = cache.read_bytes()
            previous = updated
            declarations.write_text(declarations.read_text().replace(old, new))
            updated = generate()
            assert updated != previous
            assert cache.read_bytes() != cached

        valid_cache = json.loads(cache.read_text())
        cache.write_text("invalid JSON")
        assert generate() == updated
        assert json.loads(cache.read_text()) == valid_cache
        cache.unlink()
        assert generate() == updated
        assert json.loads(cache.read_text()) == valid_cache

        # Simulate replacement of the build tool at the same executable path.
        copied_generator = directory / "MocksmithGenerator"
        shutil.copy2(generator, copied_generator)
        command[0] = str(copied_generator)
        assert generate() == updated
        previous_identity = json.loads(cache.read_text())["generator"]
        poisoned_cache = json.loads(cache.read_text())
        poisoned_cache["source"] = "// stale cached renderer output\n" + updated
        cache.write_text(json.dumps(poisoned_cache))
        executable_stat = copied_generator.stat()
        os.utime(copied_generator, ns=(
            executable_stat.st_atime_ns, executable_stat.st_mtime_ns + 2_000_000_000
        ))
        assert generate() == updated
        assert json.loads(cache.read_text())["generator"] != previous_identity
        assert "stale cached renderer output" not in cache.read_text()
        command[0] = str(generator)

        # A source-content snapshot skips parsing without relying on file mtimes.
        parent = directory / "Parent.swift"
        parent.write_text("public protocol Parent { func first() -> Int }\n")
        declarations.write_text("""import Mocksmith
import Dependency
@Mockable protocol Child: Parent {}
""")
        command.extend(["--module", "Dependency", str(parent)])
        inherited = generate()
        assert "func first() -> Int" in inherited
        parent_stat = parent.stat()
        parent.write_text(parent.read_text().replace("first", "other"))
        os.utime(parent, ns=(parent_stat.st_atime_ns, parent_stat.st_mtime_ns))
        assert parent.stat().st_size == parent_stat.st_size
        inherited = generate()
        assert "func other() -> Int" in inherited
        assert "func first() -> Int" not in inherited

        # Files that were absent from the snapshot must still be read each run.
        unrelated.write_text("@Mockable protocol AddedService {}\n")
        assert "AddedServiceMock" in generate()
        unrelated.write_text("func unrelated() -> Int { 3 }\n")
        assert generate() == inherited

        added = directory / "Added.swift"
        added.write_text("@Mockable protocol NewService {}\n")
        command.insert(command.index("--module", 6), str(added))
        assert "NewServiceMock" in generate()
        command.remove(str(added))
        added.unlink()
        assert generate() == inherited

        # Deleting a required parent cannot reuse the previous successful cache.
        parent_source = parent.read_text()
        parent.unlink()
        command.remove(str(parent))
        command.extend([str(unrelated)])
        missing_parent = subprocess.run(command, cwd=root, text=True, capture_output=True)
        assert missing_parent.returncode != 0
        assert "Parent" in missing_parent.stderr
        command[-1] = str(parent)
        parent.write_text(parent_source)
        assert generate() == inherited

        # Target and available-module identities are part of cache validity.
        command[4] = "Dependency"
        assert "ChildMock" not in generate()
        command[4] = "Fixture"
        assert generate() == inherited
        previous_snapshot = json.loads(cache.read_text())["snapshot"]
        empty = directory / "Empty.swift"
        empty.write_text("")
        command.extend(["--module", "Empty", str(empty)])
        assert generate() == inherited
        assert json.loads(cache.read_text())["snapshot"] != previous_snapshot
        del command[-3:]

        # A changed body in a retained file updates the snapshot, but the render
        # cache still preserves identical generated output and its timestamp.
        assert generate() == inherited
        os.utime(output, ns=(1_000_000_000, 1_000_000_000))
        parent.write_text(parent_source + "func unrelatedBody() -> Int { 1 }\n")
        assert generate() == inherited
        assert output.stat().st_mtime_ns == 1_000_000_000
        refreshed_cache = cache.read_bytes()
        os.utime(cache, ns=(1_000_000_000, 1_000_000_000))
        assert generate() == inherited
        assert cache.read_bytes() == refreshed_cache
        assert cache.stat().st_mtime_ns == 1_000_000_000

        # Snapshot cache hits restore missing or damaged generated files.
        output.unlink()
        assert generate() == inherited
        output.write_text("// damaged output\n")
        assert generate() == inherited
        legacy_cache = json.loads(cache.read_text())
        del legacy_cache["snapshot"]
        cache.write_text(json.dumps(legacy_cache))
        assert generate() == inherited
        assert "snapshot" in json.loads(cache.read_text())

        # Direct mocks depend only on their own module's declarations. Switching
        # inheritance on or off must change the scope of the cached snapshot.
        declarations.write_text("""import Mocksmith
import Dependency
@Mockable protocol Child {}
""")
        direct = generate()
        direct_cache = json.loads(cache.read_text())
        assert direct_cache["usesDependencySources"] is False
        assert all(source["module"] == "Fixture" for source in direct_cache["snapshot"]["sources"])
        cached = cache.read_bytes()
        os.utime(cache, ns=(1_000_000_000, 1_000_000_000))
        parent.write_text(parent.read_text().replace("other", "third"))
        assert generate() == direct
        assert cache.read_bytes() == cached
        assert cache.stat().st_mtime_ns == 1_000_000_000

        declarations.write_text(declarations.read_text().replace("Child {}", "Child: Parent {}"))
        inherited = generate()
        assert "func third() -> Int" in inherited
        assert json.loads(cache.read_text())["usesDependencySources"] is True
        parent.write_text(parent.read_text().replace("third", "fourth"))
        inherited = generate()
        assert "func fourth() -> Int" in inherited
        assert "func third() -> Int" not in inherited

        declarations.write_text(declarations.read_text().replace("Child: Parent {}", "Child {}"))
        assert generate() == direct
        assert json.loads(cache.read_text())["usesDependencySources"] is False
        legacy_cache = json.loads(cache.read_text())
        del legacy_cache["usesDependencySources"]
        cache.write_text(json.dumps(legacy_cache))
        assert generate() == direct
        assert json.loads(cache.read_text())["usesDependencySources"] is False

        # Both active and inactive conditions must fail explicitly: the build
        # tool does not receive the compiler's conditional compilation settings.
        for annotation in ["@Mockable", "@Mockable(.buildPlugin)"]:
            for condition in ["true", "false"]:
                declarations.write_text(f"""import Mocksmith
#if {condition}
{annotation} protocol ConditionalService {{}}
#endif
""")
                result = subprocess.run(command, cwd=root, text=True, capture_output=True)
                assert result.returncode != 0
                assert f"{declarations}:3:1:" in result.stderr
                assert "@Mockable build plugin generation requires an unconditional top-level protocol" in result.stderr

            for declaration in [
                f"{annotation} private protocol PrivateService {{}}",
                f"{annotation} fileprivate protocol FileprivateService {{}}",
                f"enum Scope {{ {annotation} protocol NestedService {{}} }}",
            ]:
                declarations.write_text("import Mocksmith\n" + declaration + "\n")
                result = subprocess.run(command, cwd=root, text=True, capture_output=True)
                assert result.returncode != 0
                assert "@Mockable build plugin generation requires an internal, package, or public top-level protocol" in result.stderr

        declarations.write_text("""import Mocksmith
#if compiler(>=6.0)
    #if canImport(Foundation)
        import Foundation
    #elseif os(Windows)
        import WinSDK
    #else
        let unrelatedNested = 0
    #endif
#elseif os(Linux)
    let unrelatedBranch = 0
#else
    import Foundation
#endif
#if true
    let unrelatedWithoutImports = 0
#endif
@Mockable protocol ConditionalImportService {
    func date() -> Date
}
""")
        generated = generate()
        expected_imports = """#if compiler(>=6.0)
#if canImport(Foundation)
import Foundation
#elseif os(Windows)
import WinSDK
#else
#endif
#elseif os(Linux)
#else
import Foundation
#endif"""
        assert " ".join(expected_imports.split()) in " ".join(generated.split())
        assert "unrelatedNested" not in generated
        assert "unrelatedBranch" not in generated
        assert "unrelatedWithoutImports" not in generated
        assert "#if true" not in generated

        # Compile in isolation so imports from other test files cannot hide a
        # lost condition or an omitted import in the generated source.
        modules = generator.parent / "Modules"
        macro_plugin = generator.parent / "MocksmithMacros-tool"
        if (modules / "Mocksmith.swiftmodule").exists() and macro_plugin.is_file():
            subprocess.run([
                "swiftc", "-typecheck", str(declarations), str(output),
                "-module-name", "Fixture", "-swift-version", "6",
                "-I", str(modules),
                "-load-plugin-executable", f"{macro_plugin}#MocksmithMacros",
            ], cwd=root, check=True)
        else:
            print("Skipped isolated typecheck: build the Mocksmith target first.")

    print("Generator selection, render cache, incremental output, and conditional import checks passed.")


if __name__ == "__main__":
    main()
