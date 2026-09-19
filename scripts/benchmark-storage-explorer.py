#!/usr/bin/env python3
"""Benchmark metadata scans on a temporary synthetic tree; never scan user directories."""
import argparse
import os
import platform
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", type=int, default=20_000)
    parser.add_argument("--baseline-ref", help="Optional existing git revision to compare against")
    parser.add_argument(
        "--max-peak-rss-mb",
        type=float,
        default=200,
        help="Fail when the progress-only scanner exceeds this peak resident memory (default: 200)",
    )
    args = parser.parse_args()
    if not 1 <= args.files <= 1_000_000:
        parser.error("--files must be between 1 and 1000000")
    repo = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode-beta.app/Contents/Developer")
    with tempfile.TemporaryDirectory(prefix="storage-explorer-benchmark-") as directory:
        work = Path(directory)
        fixture = work / "fixture"
        fixture.mkdir()
        for i in range(args.files):
            folder = fixture / f"folder-{i // 200:05}"
            folder.mkdir(exist_ok=True)
            (folder / f"file-{i:07}.bin").write_bytes(b"x")
        common = ["xcrun", "swiftc", "-O", "-target", platform.machine() + "-apple-macosx14.0", "-module-cache-path", str(work / "modules")]
        def run(arguments, capture=False):
            return subprocess.run(
                arguments,
                cwd=repo,
                env=env,
                check=True,
                capture_output=capture,
                text=capture,
            )
        if args.baseline_ref:
            baseline = work / "baseline"
            baseline.mkdir()
            for name in ["StorageExplorerScanner.swift", "StorageExplorerModels.swift"]:
                content = subprocess.check_output(["git", "show", f"{args.baseline_ref}:Plugins/StorageExplorer/Sources/{name}"], cwd=repo)
                (baseline / name).write_bytes(content)
            (baseline / "Benchmark.swift").write_text('''import Foundation
@main struct Benchmark {
 static func main() async throws {
  for trial in 1...3 {
   let start = Date()
   let result = try await StorageExplorerScanner().scan(rootURL: URL(fileURLWithPath: CommandLine.arguments[1]))
   print("baseline trial=\\(trial) seconds=\\(Date().timeIntervalSince(start)) bytes=\\(result.size)")
  }
 }
}
''')
            run(common + [str(path) for path in baseline.glob("*.swift")] + ["-o", str(baseline / "scan")])
            run([str(baseline / "scan"), str(fixture)])
        run(common + ["-swift-version", "6", "-emit-module", "-emit-library", "-static", "-module-name", "MacToolsFileSystem"]
            + [str(path) for path in (repo / "Sources/MacToolsFileSystem").glob("*.swift")]
            + ["-o", str(work / "libMacToolsFileSystem.a"), "-emit-module-path", str(work / "MacToolsFileSystem.swiftmodule")])
        sources = [repo / "Plugins/StorageExplorer/Sources" / name for name in
                   ["StorageExplorerModels.swift", "StorageExplorerSnapshot.swift", "StorageExplorerScanner.swift"]]
        run(common + ["-swift-version", "6", "-I", str(work), "-L", str(work), "-lMacToolsFileSystem"]
            + [str(path) for path in sources] + [str(repo / "scripts/benchmarks/storage-explorer.swift"), "-o", str(work / "scan")])
        completed = run([str(work / "scan"), str(fixture)], capture=True)
        print(completed.stdout, end="")
        peaks = []
        for line in completed.stdout.splitlines():
            for field in line.split():
                if field.startswith("peakRSS="):
                    peaks.append(int(field.split("=", 1)[1]))
        if not peaks:
            raise SystemExit("benchmark did not report peakRSS")
        limit = int(args.max_peak_rss_mb * 1024 * 1024)
        peak = max(peaks)
        if peak > limit:
            raise SystemExit(
                f"peak RSS {peak / 1024 / 1024:.1f} MiB exceeded "
                f"{args.max_peak_rss_mb:.1f} MiB"
            )


if __name__ == "__main__":
    main()
