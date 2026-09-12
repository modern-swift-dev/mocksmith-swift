#!/usr/bin/env python3
"""Exercise the production plugin import scanner and cache using standalone Swift."""

import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


def main():
    root = Path(__file__).resolve().parent.parent
    source = (root / "Plugins/MocksmithBuildPlugin/ImportScanner.swift").read_text()
    marker = "entry = ImportCache.Entry(source: source, modules:"
    assert source.count(marker) == 1, "Update cache-miss instrumentation for the scanner implementation"
    # Count real cache misses in the copied implementation, without modifying
    # production code or using wall-clock thresholds to infer reuse.
    source = "nonisolated(unsafe) private var scanCount = 0\n" + source.replace(
        marker, "scanCount += 1\n                " + marker
    )
    source += '''
struct Result: Encodable {
    let imports: [String]
    let scans: Int
}
var scanner = ImportScanner(cacheURL: URL(fileURLWithPath: CommandLine.arguments[1]))
let paths = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let imports = try scanner.importedModuleNames(in: paths)
try scanner.save()
let result = Result(imports: imports.sorted(), scans: scanCount)
print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
'''

    with TemporaryDirectory(prefix="mocksmith-plugin-import-tests-") as directory:
        directory = Path(directory)
        harness = directory / "main.swift"
        executable = directory / "scanner"
        cache = directory / "imports.json"
        harness.write_text(source)
        subprocess.run([
            "swiftc", "-swift-version", "6", str(harness), "-o", str(executable)
        ], cwd=root, check=True)

        first = directory / "First.swift"
        first.write_text("import Alpha\nfunc value() -> Int { 1 }\n")
        lexical = directory / "Lexical.swift"
        lexical.write_text(r'''import Foundation
@testable import TestModule
@preconcurrency import ConcurrentModule
public import PublicModule
import struct ScopedModule.Value
#if false
import ConditionalModule
#endif
// import FakeLine
/* outer
import FakeBlock
/* nested import FakeNested */
*/
let ordinary = "import FakeOrdinary"
let escaped = "escaped quote \" import FakeEscaped"
let raw = ##"import FakeRaw"##
let multiline = """
import FakeMultiline
"""
let rawMultiline = ##"""
import FakeRawMultiline
"""##
''')
        paths = [first, lexical]
        expected = {
            "Alpha", "Foundation", "TestModule", "ConcurrentModule",
            "PublicModule", "ScopedModule", "ConditionalModule",
        }

        def scan(expected_scans):
            result = json.loads(subprocess.check_output([
                str(executable), str(cache), *map(str, paths)
            ], cwd=root, text=True))
            assert set(result["imports"]) == expected, result
            assert result["scans"] == expected_scans, result

        scan(2)
        initial_cache = cache.read_bytes()
        os.utime(cache, ns=(1_000_000_000, 1_000_000_000))
        initial_mtime = cache.stat().st_mtime_ns
        scan(0)
        assert cache.read_bytes() == initial_cache
        assert cache.stat().st_mtime_ns == initial_mtime

        # Equal byte counts and preserved timestamps must not hide import edits.
        metadata = first.stat()
        first.write_text(first.read_text().replace("Alpha", "Bravo"))
        os.utime(first, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        assert first.stat().st_size == metadata.st_size
        assert first.stat().st_mtime_ns == metadata.st_mtime_ns
        expected.remove("Alpha")
        expected.add("Bravo")
        scan(1)
        scan(0)

        first.write_text(first.read_text().replace("{ 1 }", "{ 2 }"))
        scan(1)
        scan(0)

        first.write_text("func value() -> Int { 2 }\n")
        expected.remove("Bravo")
        scan(1)
        scan(0)

        added = directory / "Added.swift"
        added.write_text("import AddedModule\n")
        paths.append(added)
        expected.add("AddedModule")
        scan(1)
        paths.remove(added)
        added.unlink()
        expected.remove("AddedModule")
        scan(0)
        assert str(added) not in json.loads(cache.read_text())["files"]

        cache.unlink()
        scan(2)
        cache.write_text("invalid JSON")
        scan(2)
        for field, value in [("version", -1), ("executable", None)]:
            content = json.loads(cache.read_text())
            content[field] = value
            cache.write_text(json.dumps(content))
            scan(2)

        # Simulate a rebuilt plugin at the same executable path.
        metadata = executable.stat()
        os.utime(executable, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 2_000_000_000))
        scan(2)
        scan(0)

    print("Plugin import scanning and cache regressions passed.")


if __name__ == "__main__":
    main()
