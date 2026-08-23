#!/usr/bin/env python3
from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
PACKAGE_SCRIPT = SCRIPTS_DIR / "package-cli.sh"
VALIDATE_SCRIPT = SCRIPTS_DIR / "validate-release-artifacts.sh"
RELEASE_SCRIPT = SCRIPTS_DIR / "release-local.sh"


class CLIPackagingTests(unittest.TestCase):
    def run_validator(self, archive: Path, dmg: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(VALIDATE_SCRIPT),
                "--cli-archive",
                str(archive),
                "--dmg",
                str(dmg),
                "--version",
                "1.2.0",
                "--build",
                "69",
                "--allow-unsigned",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_archive_contains_one_root_level_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            binary = root / "MacToolsCLI"
            archive = root / "output" / "mactools-cli.zip"
            binary.write_bytes(b"#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)

            subprocess.run(
                [
                    str(PACKAGE_SCRIPT),
                    "--binary",
                    str(binary),
                    "--output",
                    str(archive),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.namelist(), ["mactools"])
                mode = package.getinfo("mactools").external_attr >> 16
                self.assertTrue(mode & stat.S_IXUSR)
                self.assertEqual(package.read("mactools"), binary.read_bytes())

    def test_validator_rejects_extra_archive_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "mactools-cli.zip"
            dmg = root / "MacTools.dmg"
            dmg.touch()
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("mactools", b"binary")
                package.writestr("README", b"unexpected")

            result = self.run_validator(archive, dmg)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one root entry", result.stderr)

    def test_validator_rejects_symlink_cli_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "mactools-cli.zip"
            dmg = root / "MacTools.dmg"
            dmg.touch()
            info = zipfile.ZipInfo("mactools")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr(info, "elsewhere")

            result = self.run_validator(archive, dmg)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("regular executable", result.stderr)

    def test_validator_rejects_non_universal_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            binary = root / "MacToolsCLI"
            archive = root / "mactools-cli.zip"
            dmg = root / "MacTools.dmg"
            binary.write_bytes(b"#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            dmg.touch()
            subprocess.run(
                [
                    str(PACKAGE_SCRIPT),
                    "--binary",
                    str(binary),
                    "--output",
                    str(archive),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            result = self.run_validator(archive, dmg)

            self.assertNotEqual(result.returncode, 0)

    def test_validator_rejects_non_exact_executable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "mactools-cli.zip"
            dmg = root / "MacTools.dmg"
            dmg.touch()
            info = zipfile.ZipInfo("mactools")
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr(info, b"binary")

            result = self.run_validator(archive, dmg)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact mode 0755", result.stderr)

    def test_release_validator_is_shared_and_signs_cli_before_outer_app(self) -> None:
        local_release = RELEASE_SCRIPT.read_text()
        release_workflow = (SCRIPTS_DIR.parent / ".github/workflows/release.yml").read_text()
        validator = VALIDATE_SCRIPT.read_text()

        main_flow = local_release.index('info "Signing standalone CLI before the outer app"')
        self.assertLess(
            local_release.index('sign_cli_binary \\\n', main_flow),
            local_release.index('sign_app_bundle "$SIGNED_APP_PATH"', main_flow),
        )
        self.assertIn("validate-release-artifacts.sh", local_release)
        self.assertIn("validate-release-artifacts.sh", release_workflow)
        for invariant in (
            "arm64",
            "x86_64",
            "cliVersion",
            "cliBuild",
            "TeamIdentifier",
            "runtime",
            'if "mactools" in os.listdir',
            "MacToolsCLIBroker",
            "CFBundleIdentifier",
            "MachServices",
            "BundleProgram",
        ):
            self.assertIn(invariant, validator)

    def test_local_release_rejects_tag_that_does_not_match_version(self) -> None:
        environment = os.environ.copy()
        environment["RELEASE_CONFIG_FILE"] = str(
            SCRIPTS_DIR.parent / "build/nonexistent-release-config"
        )

        result = subprocess.run(
            [
                str(RELEASE_SCRIPT),
                "--version",
                "1.2.0",
                "--build-number",
                "69",
                "--tag",
                "v1.2.0-local",
                "--skip-sign",
            ],
            cwd=SCRIPTS_DIR.parent,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v1.2.0", result.stderr)
        self.assertIn("v1.2.0-local", result.stderr)


if __name__ == "__main__":
    unittest.main()
