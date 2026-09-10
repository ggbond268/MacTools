from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT_DIR / ".github/workflows/release.yml"
LOCAL_SCRIPT_PATH = ROOT_DIR / "scripts/release-local.sh"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode")
class ReleaseAppSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.temporary_directory.name) / "unsigned-tool"
        subprocess.run(
            ["xcrun", "clang", "-x", "c", "-", "-Wl,-no_adhoc_codesign", "-o", str(cls.executable)],
            input="int main(void) { return 0; }\n",
            text=True,
            capture_output=True,
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def make_app(self, root: Path, *, include_broker: bool) -> Path:
        app = root / "Build/Products/Release/MacTools.app"
        extension = app / "Contents/PlugIns/RightClickFinderSync.appex"
        for bundle, name, package_type in (
            (app, "MacTools", "APPL"),
            (extension, "RightClickFinderSync", "XPC!"),
        ):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(self.executable, bundle / "Contents/MacOS" / name)
            info = {
                "CFBundleExecutable": name,
                "CFBundleIdentifier": f"dev.mactools.signing-test.{name}",
                "CFBundlePackageType": package_type,
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.3.0",
            }
            if bundle == extension:
                info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.FinderSync"}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        if include_broker:
            shutil.copy2(self.executable, app / "Contents/MacOS/MacToolsCLIBroker")
        return app

    def run_signing(self, source: str, root: Path) -> subprocess.CompletedProcess[str]:
        if source == "workflow":
            step = WORKFLOW_PATH.read_text().split("      - name: Sign app bundle\n", 1)[1]
            script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        else:
            script = LOCAL_SCRIPT_PATH.read_text().split("function sign_path() {", 1)[1]
            script = "function sign_path() {" + script.split("function sign_disk_image() {", 1)[0]
            script += '\nsign_app_bundle "$DERIVED_DATA/Build/Products/Release/MacTools.app"\n'

        # Exercise real code signing without production credentials or timestamp requests.
        script = script.replace("/usr/bin/codesign", "codesign_for_test")
        shim = """
        set -euo pipefail
        fail() { echo "$*" >&2; exit 1; }
        codesign_for_test() {
          local args=()
          while [[ "$#" -gt 0 ]]; do
            case "$1" in
              --keychain) shift 2 ;;
              --timestamp) shift ;;
              *) args+=("$1"); shift ;;
            esac
          done
          /usr/bin/codesign "${args[@]}"
        }
        """
        environment = os.environ.copy()
        environment.update(
            DERIVED_DATA=str(root),
            PROJECT_NAME="MacTools",
            SIGNING_IDENTITY="-",
            DEVELOPER_ID_APPLICATION="-",
            KEYCHAIN_PATH="unused-test-keychain",
            APP_ENTITLEMENTS="Configs/MacTools.entitlements",
            FINDER_SYNC_ENTITLEMENTS="Sources/Extensions/RightClickFinderSync/RightClickFinderSync.entitlements",
        )
        return subprocess.run(
            ["/bin/bash", "-c", textwrap.dedent(shim) + script],
            cwd=ROOT_DIR,
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_unsigned_broker_is_signed_before_the_app(self) -> None:
        for source in ("workflow", "local"):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = self.make_app(root, include_broker=True)
                result = self.run_signing(source, root)
                self.assertEqual(result.returncode, 0, result.stderr)
                broker = app / "Contents/MacOS/MacToolsCLIBroker"
                for path in (broker, app):
                    verification = subprocess.run(
                        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
                        text=True,
                        capture_output=True,
                    )
                    self.assertEqual(verification.returncode, 0, verification.stderr)
                signature = subprocess.run(
                    ["/usr/bin/codesign", "-d", "--verbose=4", str(broker)],
                    text=True,
                    capture_output=True,
                    check=True,
                )
                self.assertIn("runtime", signature.stderr)

    def test_missing_broker_blocks_signing(self) -> None:
        for source in ("workflow", "local"):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_app(root, include_broker=False)
                result = self.run_signing(source, root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Release CLI broker is missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
