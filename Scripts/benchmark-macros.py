#!/usr/bin/env python3
"""Measure expansion and type-checking with dependencies already built.

Run from any directory with Python 3 and the package's Swift 6.3 toolchain.
On macOS, DEVELOPER_DIR can select the Xcode installation to benchmark.
Each sample uses a fresh compiler process; package/dependency build time is excluded.
"""

from pathlib import Path
from statistics import median
import subprocess
from tempfile import TemporaryDirectory
from time import perf_counter


def main():
    root = Path(__file__).resolve().parent.parent
    subprocess.run(["swift", "--version"], cwd=root, check=True)
    subprocess.run(["swift", "build", "--target", "Mocksmith"], cwd=root, check=True)
    binary_path = Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=root, text=True
    ).strip())
    plugin = binary_path / "MocksmithMacros-tool"
    if not plugin.is_file():
        raise FileNotFoundError(plugin)

    with TemporaryDirectory(prefix="mocksmith-benchmark-") as directory:
        source = Path(directory) / "Benchmark.swift"
        for protocols, members in [(20, 10), (1, 100)]:
            declarations = ["import Mocksmith"]
            for index in range(protocols):
                declarations.append(f"@Mockable protocol Service{index} {{")
                declarations.extend(
                    f"func method{member}(_ value: String, count: Int) -> String"
                    for member in range(members)
                )
                declarations.append("}")
            source.write_text("\n".join(declarations) + "\n")
            command = [
                "swiftc", "-typecheck", str(source), "-module-name", "Benchmark",
                "-swift-version", "6", "-I", str(binary_path / "Modules"),
                "-load-plugin-executable", f"{plugin}#MocksmithMacros",
            ]
            # Warm filesystem/module caches before collecting comparable samples.
            subprocess.run(command, cwd=root, check=True)
            samples = []
            for _ in range(3):
                start = perf_counter()
                subprocess.run(command, cwd=root, check=True)
                samples.append(perf_counter() - start)
            print(
                f"{protocols} protocols x {members} methods: "
                f"median {median(samples):.3f}s; "
                f"samples {', '.join(f'{sample:.3f}s' for sample in samples)}",
                flush=True,
            )


if __name__ == "__main__":
    main()
