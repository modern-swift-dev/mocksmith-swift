#!/usr/bin/env python3
"""Compare macro and build-plugin generation during incremental compilation.

Run from any directory with Python 3 and the package's Swift 6.3 toolchain.
On macOS, DEVELOPER_DIR can select the Xcode installation to benchmark.
This exercises Swift's incremental compiler with 20 protocols of 10 methods each.
It excludes initial compilation, dependency builds, linking, and test execution;
the results are not measurements of an entire Xcode build.
"""

import json
from pathlib import Path
from statistics import median
import subprocess
from tempfile import TemporaryDirectory
from time import perf_counter


def main():
    root = Path(__file__).resolve().parent.parent
    subprocess.run(["swift", "--version"], cwd=root, check=True)
    subprocess.run(["swift", "build", "--product", "MocksmithGenerator"], cwd=root, check=True)
    subprocess.run(["swift", "build", "--target", "Mocksmith"], cwd=root, check=True)
    binary_path = Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=root, text=True
    ).strip())
    plugin = binary_path / "MocksmithMacros-tool"
    generator = binary_path / "MocksmithGenerator"
    for executable in (plugin, generator):
        if not executable.is_file():
            raise FileNotFoundError(executable)

    with TemporaryDirectory(prefix="mocksmith-benchmark-") as directory:
        for mode in ("macro", "buildPlugin"):
            case = Path(directory) / mode
            case.mkdir()
            mocks = case / "Mocks.swift"
            consumer = case / "Consumer.swift"
            unrelated = case / "Unrelated.swift"
            generated = case / "Generated.swift"
            sources = [mocks, consumer, unrelated]
            attribute = "@Mockable(.macro)" if mode == "macro" else "@Mockable"
            declarations = ["import Mocksmith"]
            for index in range(20):
                declarations.append(f"{attribute} protocol Service{index} {{")
                declarations.extend(
                    f"func method{member}(_ value: String, count: Int) -> String"
                    for member in range(10)
                )
                declarations.append("}")
            mocks.write_text("\n".join(declarations) + "\n")
            unrelated.write_text("func unrelatedValue() -> Int { 42 }\n")

            def write_consumer(revision):
                lines = ["import Mocksmith", "func consume() -> [String] {", "var results: [String] = []"]
                for index in range(20):
                    lines.extend([
                        f"let mock{index} = Service{index}Mock()",
                        f'Given(mock{index}).method0(.value("input"), count: .value(1)).willReturn("output{revision}")',
                        f'results.append(mock{index}.method0("input", count: 1))',
                    ])
                lines.extend(["return results", "}"])
                consumer.write_text("\n".join(lines) + "\n")

            write_consumer(0)
            compilation_sources = sources + ([generated] if mode == "buildPlugin" else [])
            output_map = {"": {"swift-dependencies": str(case / "master.swiftdeps")}}
            for source in compilation_sources:
                output_map[str(source)] = {
                    "object": str(source.with_suffix(".o")),
                    "swift-dependencies": str(source.with_suffix(".swiftdeps")),
                }
            output_map_path = case / "output-file-map.json"
            output_map_path.write_text(json.dumps(output_map))
            command = [
                "swiftc", "-c", "-emit-module", "-parse-as-library",
                "-incremental", "-enable-batch-mode", "-j", "4",
                "-module-name", "Benchmark", "-emit-module-path", str(case / "Benchmark.swiftmodule"),
                "-output-file-map", str(output_map_path),
                "-swift-version", "6", "-I", str(binary_path / "Modules"),
                "-load-plugin-executable", f"{plugin}#MocksmithMacros",
                *map(str, compilation_sources),
            ]

            def compile_sources():
                if mode == "buildPlugin":
                    subprocess.run([
                        str(generator), "--output", str(generated),
                        "--target-module", "Benchmark", "--module", "Benchmark", *map(str, sources),
                    ], cwd=root, check=True)
                subprocess.run(command, cwd=root, check=True)

            # Populate incremental build records before measuring edits.
            compile_sources()
            samples = []
            for revision in range(1, 4):
                write_consumer(revision)
                start = perf_counter()
                compile_sources()
                samples.append(perf_counter() - start)
            start = perf_counter()
            # The build tool is skipped when none of its inputs changed. This still
            # invokes swiftc; an Xcode no-op build may skip the compiler entirely.
            subprocess.run(command, cwd=root, check=True)
            unchanged = perf_counter() - start
            print(
                f"{mode}, 20 protocols x 10 methods, consumer body edits: "
                f"median {median(samples):.3f}s; "
                f"samples {', '.join(f'{sample:.3f}s' for sample in samples)}; "
                f"unchanged compiler invocation {unchanged:.3f}s",
                flush=True,
            )


if __name__ == "__main__":
    main()
