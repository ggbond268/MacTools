from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT_DIR / "scripts/plugins/preflight-app-plugin-catalog.swift"
SIGNED_CATALOG = ROOT_DIR / "docs/plugins/v4/catalog.json"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode")
class AppPluginCatalogPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.temporary_directory.name) / "catalog-preflight"
        subprocess.run(
            ["xcrun", "swiftc", str(SCRIPT_PATH), "-o", str(cls.executable)],
            cwd=ROOT_DIR,
            check=True,
            text=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def run_preflight(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(self.executable),
                "--required-plugin-kit-version",
                "4",
                "--required-schema-version",
                "2",
                *arguments,
            ],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

    def test_schema3_source_cannot_reuse_the_released_1_2_version(self) -> None:
        result = self.run_preflight("--app-version", "1.2.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be released as MacTools 1.2.0", result.stderr)
        self.assertIn("Raise the app version to 1.2.1", result.stderr)

    def test_matching_committed_and_deployed_signed_catalog_passes(self) -> None:
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(SIGNED_CATALOG),
            "--deployed-catalog",
            str(SIGNED_CATALOG),
            "--catalog-url",
            "https://example.invalid/catalog.json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified signed PluginKit 4 catalog", result.stdout)

    def test_schema3_hosts_derive_the_current_plugin_kit_compatibility_line(self) -> None:
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn('sourcePluginKitVersion()', source)
        self.assertIn('v5/schema3/catalog.json', source)
        self.assertIn('requiredSchemaVersion ?? 3', source)

    def test_future_plugin_kit_defaults_to_its_own_catalog(self) -> None:
        result = subprocess.run(
            [
                str(self.executable),
                "--required-plugin-kit-version", "6",
                "--app-version", "1.3.0",
            ],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/plugins/v6/catalog.json", result.stderr)

    def test_default_preflight_rejects_schema2_on_the_schema3_line(self) -> None:
        result = subprocess.run(
            [
                str(self.executable),
                "--required-plugin-kit-version", "4",
                "--app-version", "1.2.1",
                "--expected-catalog", str(SIGNED_CATALOG),
                "--deployed-catalog", str(SIGNED_CATALOG),
            ],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use catalog schema 3", result.stderr)

    def test_missing_catalog_fails_with_release_order_guidance(self) -> None:
        missing = Path(self.temporary_directory.name) / "missing.json"
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(missing),
            "--deployed-catalog",
            str(missing),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Publish the plugin batch first", result.stderr)
        self.assertIn("Release order:", result.stderr)

    def test_invalid_signature_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["generatedAt"] = "2099-01-01T00:00:00Z"
        tampered = Path(self.temporary_directory.name) / "tampered.json"
        tampered.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(tampered),
            "--deployed-catalog",
            str(tampered),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature does not match", result.stderr)

    def test_wrong_catalog_id_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["catalogID"] = "example.wrong.catalog"
        invalid = Path(self.temporary_directory.name) / "wrong-id.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use catalog ID com.ggbond.mactools.plugins", result.stderr)

    def test_malformed_minimum_host_version_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["minimumHostVersion"] = "future"
        invalid = Path(self.temporary_directory.name) / "malformed-floor.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid app version: future", result.stderr)

    def test_catalog_requiring_newer_host_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["minimumHostVersion"] = "1.3.0"
        invalid = Path(self.temporary_directory.name) / "future-floor.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires MacTools 1.3.0", result.stderr)
        self.assertIn("target app 1.2.1", result.stderr)


if __name__ == "__main__":
    unittest.main()
