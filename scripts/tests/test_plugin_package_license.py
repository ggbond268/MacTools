import json
import pathlib
import subprocess
import tempfile
import unittest
import zipfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE_BUILDER = REPO_ROOT / "scripts/plugins/build-plugin-package.sh"


class PluginPackageLicenseTests(unittest.TestCase):
    def make_package(self, root: pathlib.Path) -> pathlib.Path:
        package = root / "Demo.mactoolsplugin"
        bundle = package / "Demo.bundle"
        bundle.mkdir(parents=True)
        (package / "plugin.json").write_text(
            json.dumps(
                {
                    "id": "demo",
                    "bundleRelativePath": "Demo.bundle",
                }
            ),
            encoding="utf-8",
        )
        (bundle / "payload").write_text("demo", encoding="utf-8")
        return package

    def test_explicit_license_is_copied_before_zip_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self.make_package(root)
            output = root / "dist"
            license_file = root / "PROJECT-LICENSE"
            license_file.write_text("license text\n", encoding="utf-8")

            result = subprocess.run(
                [
                    str(PACKAGE_BUILDER),
                    "--source",
                    str(source),
                    "--output-dir",
                    str(output),
                    "--license-file",
                    str(license_file),
                    "--zip",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            package_copy = output / source.name
            self.assertEqual(
                (package_copy / "LICENSE").read_text(encoding="utf-8"),
                "license text\n",
            )
            archive_path = pathlib.Path(result.stdout.strip())
            with zipfile.ZipFile(archive_path) as archive:
                self.assertEqual(
                    archive.read(f"{source.name}/LICENSE"),
                    b"license text\n",
                )

    def test_omitted_license_does_not_relicense_external_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self.make_package(root)
            output = root / "dist"

            subprocess.run(
                [
                    str(PACKAGE_BUILDER),
                    "--source",
                    str(source),
                    "--output-dir",
                    str(output),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertFalse((output / source.name / "LICENSE").exists())

    def test_missing_explicit_license_fails_before_copying(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self.make_package(root)
            output = root / "dist"

            result = subprocess.run(
                [
                    str(PACKAGE_BUILDER),
                    "--source",
                    str(source),
                    "--output-dir",
                    str(output),
                    "--license-file",
                    str(root / "missing"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("License file not found", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
