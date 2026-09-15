#!/usr/bin/env python3
"""Capture synthetic production-panel rectangles requested by opt-in XCTest.

Run on an unlocked desktop with Screen Recording access for the invoking terminal.
The output directory must be new. Keep other windows clear of the review display:
rectangle captures include any overlapping windows. Global settings are not changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--panels-only", action="store_true",
                        help="Skip surface regression tests when comparing an older host source")
    parser.add_argument("--native-drag", action="store_true",
                        help="Inject pointer input through each test panel's native drag handle")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    env["TEST_RUNNER_MACTOOLS_PALETTE_CAPTURE_DIR"] = str(output)
    env["TEST_RUNNER_MACTOOLS_PALETTE_EXTERNAL_CAPTURE"] = "1"
    command = [
        "xcodebuild", "-project", "MacTools.xcodeproj", "-scheme", "MacTools",
        "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", "build/DerivedData", "-parallel-testing-enabled", "NO",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
        "test", "-quiet",
        "-only-testing:MacToolsTests/AppWindowRouterTests/testCaptureCommandPaletteAppearanceForReview",
        "-only-testing:MacToolsTests/ClipboardHistoryPluginTests/testCaptureClipboardAppearanceForReview",
    ]
    if not args.panels_only:
        command.append("-only-testing:MacToolsTests/PluginPaletteSurfaceTests")
    completed = set()
    with (output / "validation.log").open("w") as log:
        pointer_helper = output / "native-pointer-drag"
        if args.native_drag:
            subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/e2e/PalettePointerDrag.swift"),
                            "-module-cache-path", str(output / "module-cache"), "-o", str(pointer_helper)],
                           check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 1200
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError("Native capture validation exceeded 20 minutes")
                for request_file in output.glob("*/capture-request.json"):
                    request = json.loads(request_file.read_text())
                    target = Path(request["output"]).resolve()
                    if target in completed:
                        continue
                    if not target.is_relative_to(output) or target.suffix != ".png":
                        raise ValueError("Capture target must be a PNG inside the output directory")
                    window_id = int(request["windowID"])
                    if window_id <= 0:
                        raise ValueError("Capture requires a valid test window ID")
                    rect = request["rect"]
                    if len(rect) != 4 or not all(isinstance(value, int) for value in rect) or min(rect[2:]) <= 0:
                        raise ValueError("Capture requires the test panel's rectangle")
                    if args.native_drag and target.stem[3:] == "moved-resized":
                        point = request.get("dragPoint")
                        if not isinstance(point, list) or len(point) != 2:
                            raise ValueError("Native drag requires the production handle's coordinates")
                        drag = subprocess.run([str(pointer_helper), str(window_id), *map(str, point),
                                               str(ROOT / "build/DerivedData/Build/Products")],
                                              capture_output=True, text=True, timeout=8)
                        if drag.returncode:
                            log.write(drag.stdout + drag.stderr)
                            log.flush()
                            raise RuntimeError("Native pointer drag failed; see validation.log")
                        result = json.loads(drag.stdout)
                        target.with_suffix(".drag.json").write_text(drag.stdout)
                        rect = result["rect"]
                    temporary = target.with_name(target.stem + ".pending.png")
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-R", ",".join(map(str, rect)), str(temporary)],
                                   check=True, stdout=log, stderr=subprocess.STDOUT, timeout=10)
                    temporary.replace(target)
                    completed.add(target)
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
    print(f"Captured {len(completed)} panel frames in {output}")
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
