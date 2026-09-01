import json
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "scripts/licenses/generate-third-party-notices.py"
EMBED_APP = REPO_ROOT / "scripts/licenses/embed-app-legal-notices.sh"
MANIFEST = REPO_ROOT / "Sources/Resources/ThirdPartyNotices/manifest.json"


class ThirdPartyNoticeTests(unittest.TestCase):
    def run_generator(
        self,
        product: str,
        output: pathlib.Path,
        *,
        manifest: pathlib.Path = MANIFEST,
        repo_root: pathlib.Path = REPO_ROOT,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(GENERATOR),
                "--manifest",
                str(manifest),
                "--repo-root",
                str(repo_root),
                "--product",
                product,
                "--output",
                str(output),
            ],
            check=check,
            capture_output=True,
            text=True,
        )

    def test_repository_manifest_generates_filtered_app_notices(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "THIRD_PARTY_NOTICES.txt"
            self.run_generator("app", output)

            notice = output.read_text(encoding="utf-8")
            self.assertIn("Sparkle", notice)
            self.assertIn("MenuBarExtraAccess", notice)
            self.assertNotIn("activity-bar", notice)

    def test_plugin_notices_include_only_matching_components(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "THIRD_PARTY_NOTICES.txt"
            self.run_generator("plugin:mouse-enhancer", output)

            notice = output.read_text(encoding="utf-8")
            self.assertIn("MiddleClick", notice)
            self.assertIn("everypinch", notice)
            self.assertIn("hs._asm.undocumented.touchdevice", notice)
            self.assertNotIn("Sparkle", notice)
            self.assertIn(
                "The complete license text is provided in LICENSE alongside this notice.",
                notice,
            )

    def test_product_without_components_removes_stale_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "THIRD_PARTY_NOTICES.txt"
            output.write_text("stale", encoding="utf-8")

            self.run_generator("plugin:calendar", output)

            self.assertFalse(output.exists())

    def test_manifest_rejects_missing_license_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source.swift"
            source.write_text("", encoding="utf-8")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "components": [
                            {
                                "id": "example",
                                "name": "Example",
                                "repository": "https://example.com/example",
                                "revision": "0" * 40,
                                "license": "MIT",
                                "gpl3Compatibility": "compatible",
                                "relationship": "adapted",
                                "products": ["app"],
                                "paths": ["Source.swift"],
                                "licenseFile": "missing.txt",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            output = root / "notice.txt"

            result = self.run_generator(
                "app",
                output,
                manifest=manifest,
                repo_root=root,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("licenseFile does not exist", result.stderr)
            self.assertFalse(output.exists())

    def test_distributed_component_requires_explicit_gpl3_compatibility(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            (root / "Source.swift").write_text("", encoding="utf-8")
            (root / "LICENSE").write_text("license", encoding="utf-8")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "components": [
                            {
                                "id": "example",
                                "name": "Example",
                                "repository": "https://example.com/example",
                                "revision": "0" * 40,
                                "license": "Example-1.0",
                                "gpl3Compatibility": "incompatible",
                                "relationship": "bundled",
                                "products": ["app"],
                                "paths": ["Source.swift"],
                                "licenseFile": "LICENSE",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_generator(
                "app",
                root / "notice.txt",
                manifest=manifest,
                repo_root=root,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("gpl3Compatibility must be 'compatible'", result.stderr)

    def test_app_embed_copies_one_license_and_generated_notices(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_bundle = pathlib.Path(temporary_directory) / "MacTools.app"
            (app_bundle / "Contents").mkdir(parents=True)

            subprocess.run(
                [str(EMBED_APP), "--app-bundle", str(app_bundle)],
                check=True,
                capture_output=True,
                text=True,
            )

            resources = app_bundle / "Contents/Resources"
            self.assertEqual(
                (resources / "LICENSE").read_bytes(),
                (REPO_ROOT / "LICENSE").read_bytes(),
            )
            notice = (resources / "THIRD_PARTY_NOTICES.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn("Sparkle", notice)
            self.assertNotIn("activity-bar", notice)


if __name__ == "__main__":
    unittest.main()
