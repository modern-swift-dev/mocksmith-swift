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
