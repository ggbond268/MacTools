from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
import unicodedata
import zipfile
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
SCRIPTS_ROOT = REPO_ROOT / "scripts" / "plugins"
GENERATOR = SCRIPTS_ROOT / "generate-plugin-catalog.py"
COPY_MANIFEST = SCRIPTS_ROOT / "copy-plugin-manifest.py"
sys.path.insert(0, str(SCRIPTS_ROOT))

SPEC = importlib.util.spec_from_file_location("generate_plugin_catalog", GENERATOR)
assert SPEC is not None and SPEC.loader is not None
generate_plugin_catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generate_plugin_catalog)


def projected_manifest(**overrides: object) -> dict[str, object]:
    manifest: dict[str, object] = {
        "id": "com.example.mactools.demo",
        "displayName": "Demo",
        "summary": "Demo plugin",
        "version": "1.0.0",
        "minHostVersion": "1.2.1",
        "pluginKitVersion": 5,
        "bundleRelativePath": "Demo.bundle",
        "capabilities": {
            "primaryPanel": False,
            "componentPanel": False,
            "settings": "none",
        },
        "permissions": [],
        "category": "other",
    }
    manifest.update(overrides)
    return manifest


class GeneratePluginCatalogTests(unittest.TestCase):
    def make_package(
        self,
        root: pathlib.Path,
        manifest: dict[str, object] | None = None,
        name: str = "Demo.mactoolsplugin",
    ) -> pathlib.Path:
        package = root / name
        package.mkdir()
        package.joinpath("plugin.json").write_text(
            json.dumps(manifest or projected_manifest()),
            encoding="utf-8",
        )
        return package

    def run_generator(
        self,
        root: pathlib.Path,
        package: pathlib.Path,
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--mode", "debug",
                "--output", str(root / "catalog.json"),
                "--package", str(package),
                "--plugins-root", str(root / "Sources"),
                *arguments,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_existing_projected_package_is_authoritative_without_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = self.make_package(
                root,
                projected_manifest(releaseChannel="beta"),
            )

            result = self.run_generator(root, package)

            self.assertEqual(result.returncode, 0, result.stderr)
            entry = json.loads((root / "catalog.json").read_text(encoding="utf-8"))["plugins"][0]
            self.assertEqual(entry["releaseChannel"], "beta")

    def test_source_and_package_metadata_must_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = root / "Appearance.mactoolsplugin"
            package.mkdir()
            source = PLUGINS_ROOT / "Appearance" / "plugin.json"
            subprocess.run(
                [
                    sys.executable,
                    str(COPY_MANIFEST),
                    "copy",
                    "--source", str(source),
                    "--destination", str(package / "plugin.json"),
                    "--configuration", "Release",
                    "--app-version-config", str(REPO_ROOT / "Configs/AppVersion.xcconfig"),
                ],
                check=True,
            )
            packaged = json.loads((package / "plugin.json").read_text(encoding="utf-8"))
            packaged["releaseChannel"] = "mismatched"
            (package / "plugin.json").write_text(json.dumps(packaged), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--mode", "debug",
                    "--output", str(root / "catalog.json"),
                    "--package", str(package),
                    "--plugins-root", str(PLUGINS_ROOT),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match its source manifest: releaseChannel", result.stderr)

    def test_duplicate_package_plugin_ids_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            first = self.make_package(root, name="First.mactoolsplugin")
            second = self.make_package(root, name="Second.mactoolsplugin")

            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--mode", "debug",
                    "--output", str(root / "catalog.json"),
                    "--package", str(first),
                    "--package", str(second),
                    "--plugins-root", str(root / "Sources"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Duplicate package plugin ID", result.stderr)

    def test_invalid_catalog_arguments_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = self.make_package(root)
            cases = {
                "blank catalog ID": ("--catalog-id", "   "),
                "invalid generated timestamp": ("--generated-at", "not-a-date"),
                "insecure release notes URL": ("--release-notes-url", "http://example.com/notes"),
                "insecure base URL": ("--base-url", "http://example.com/plugins"),
            }
            for name, arguments in cases.items():
                with self.subTest(name=name):
                    result = self.run_generator(root, package, *arguments)
                    self.assertNotEqual(result.returncode, 0)

    def test_directory_metrics_skip_symlinked_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            root.joinpath("payload").write_bytes(b"included")
            root.joinpath("linked").symlink_to(root / "payload")

            digest, size = generate_plugin_catalog.directory_metrics(root)

            expected = hashlib.sha256(b"payload\0included\0").hexdigest()
            self.assertEqual((digest, size), (expected, len(b"included")))

    @unittest.skipUnless(hasattr(stat, "UF_HIDDEN"), "requires macOS hidden file flags")
    def test_directory_metrics_skip_finder_hidden_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            hidden = root / "payload"
            hidden.write_bytes(b"hidden")
            os.chflags(hidden, stat.UF_HIDDEN)

            digest, size = generate_plugin_catalog.directory_metrics(root)

            self.assertEqual(digest, hashlib.sha256().hexdigest())
            self.assertEqual(size, 0)

    def test_zip_preflight_rejects_traversal_and_unsupported_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            for name, member_name, attributes in (
                ("traversal", "../escape", None),
                ("fifo", "Demo.mactoolsplugin/fifo", (stat.S_IFIFO | 0o644) << 16),
            ):
                with self.subTest(name=name):
                    archive_path = root / f"{name}.zip"
                    with zipfile.ZipFile(archive_path, "w") as archive:
                        archive.writestr(
                            "Demo.mactoolsplugin/plugin.json",
                            json.dumps(projected_manifest()),
                        )
                        if attributes is None:
                            archive.writestr(member_name, b"bad")
                        else:
                            info = zipfile.ZipInfo(member_name)
                            info.create_system = 3
                            info.external_attr = attributes
                            archive.writestr(info, b"bad")
                    with self.assertRaises(SystemExit):
                        generate_plugin_catalog.packaged_manifest(archive_path)

    def test_zip_preflight_bounds_expansion_and_symlink_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            archive_path = root / "package.zip"
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(
                    "Demo.mactoolsplugin/plugin.json",
                    json.dumps(projected_manifest()),
                )
                archive.writestr("Demo.mactoolsplugin/payload", b"x" * 1024)
            with mock.patch.object(generate_plugin_catalog, "MAX_ARCHIVE_EXPANDED_BYTES", 512):
                with self.assertRaisesRegex(SystemExit, "expands beyond"):
                    generate_plugin_catalog.packaged_manifest(archive_path)

            for target, accepted in (("Demo.bundle/file", True), ("../../escape", False)):
                symlink_archive = root / ("safe.zip" if accepted else "escape.zip")
                with zipfile.ZipFile(symlink_archive, "w") as archive:
                    archive.writestr(
                        "Demo.mactoolsplugin/plugin.json",
                        json.dumps(projected_manifest()),
                    )
                    info = zipfile.ZipInfo("Demo.mactoolsplugin/link")
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, target)
                if accepted:
                    manifest, _ = generate_plugin_catalog.packaged_manifest(symlink_archive)
                    self.assertEqual(manifest["id"], "com.example.mactools.demo")
                else:
                    with self.assertRaisesRegex(SystemExit, "escaping symlink"):
                        generate_plugin_catalog.packaged_manifest(symlink_archive)

    def test_zip_preflight_rejects_crc_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            archive_path = pathlib.Path(temporary_directory) / "corrupt.zip"
            payload_name = "Demo.mactoolsplugin/Demo.bundle/payload"
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(
                    "Demo.mactoolsplugin/plugin.json",
                    json.dumps(projected_manifest()),
                )
                archive.writestr(payload_name, b"original")
            with zipfile.ZipFile(archive_path) as archive:
                info = archive.getinfo(payload_name)
                payload_offset = (
                    info.header_offset
                    + 30
                    + len(info.filename.encode("utf-8"))
                    + len(info.extra)
                )
            data = bytearray(archive_path.read_bytes())
            data[payload_offset] ^= 1
            archive_path.write_bytes(data)

            with self.assertRaisesRegex(SystemExit, "unreadable data"):
                generate_plugin_catalog.packaged_manifest(archive_path)

    def test_zip_preflight_normalizes_unicode_duplicate_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            archive_path = pathlib.Path(temporary_directory) / "unicode.zip"
            nfc_name = "café"
            nfd_name = unicodedata.normalize("NFD", nfc_name)
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr(
                    "Demo.mactoolsplugin/plugin.json",
                    json.dumps(projected_manifest()),
                )
                archive.writestr(f"Demo.mactoolsplugin/{nfc_name}", b"first")
                archive.writestr(f"Demo.mactoolsplugin/{nfd_name}", b"second")

            with self.assertRaisesRegex(SystemExit, "duplicate archive path"):
                generate_plugin_catalog.packaged_manifest(archive_path)


if __name__ == "__main__":
    unittest.main()
