#!/usr/bin/env python3
from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
PACKAGE_SCRIPT = SCRIPTS_DIR / "package-cli.sh"
VALIDATE_SCRIPT = SCRIPTS_DIR / "validate-release-artifacts.sh"
VALIDATE_LAYOUT_SCRIPT = SCRIPTS_DIR / "validate-release-layout.py"
CHECKSUM_SCRIPT = SCRIPTS_DIR / "write-sha256.sh"
BINARY_VALIDATION_SCRIPT = SCRIPTS_DIR / "release_binary_validation.py"
RELEASE_SCRIPT = SCRIPTS_DIR / "release-local.sh"


class CLIPackagingTests(unittest.TestCase):
    host_identifier = "app.ggbond.MacTools"

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

    def run_binary_validator(self, *arguments: str, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [str(BINARY_VALIDATION_SCRIPT), *arguments],
            input=stdin,
            check=False,
            capture_output=True,
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

    def test_binary_policy_rejects_missing_extra_and_duplicate_architectures(self) -> None:
        valid = self.run_binary_validator(
            "architectures", "--value", "x86_64 arm64", "--role", "CLI"
        )
        self.assertEqual(valid.returncode, 0, valid.stderr.decode())
        for role in ("Host", "Broker", "CLI"):
            for architectures in ("arm64", "arm64 x86_64 i386", "arm64 arm64"):
                with self.subTest(role=role, architectures=architectures):
                    result = self.run_binary_validator(
                        "architectures", "--value", architectures, "--role", role
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(b"exactly arm64 and x86_64", result.stderr)

    def test_otool_info_plist_parser_round_trips_every_word(self) -> None:
        value = {
            "CFBundleIdentifier": "app.ggbond.MacTools.cli",
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "69",
        }
        payload = plistlib.dumps(value, fmt=plistlib.FMT_XML)
        padded = payload + b"\0" * (-len(payload) % 4)
        words = [padded[index : index + 4][::-1].hex() for index in range(0, len(padded), 4)]
        lines = ["Contents of (__TEXT,__info_plist) section"]
        for index in range(0, len(words), 4):
            lines.append(f"{index * 4:016x} " + " ".join(words[index : index + 4]))

        result = self.run_binary_validator(
            "extract-info",
            stdin=("\n".join(lines) + "\n").encode(),
        )

        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(plistlib.loads(result.stdout), value)

    def test_embedded_metadata_policy_rejects_each_role_slice_mutation(self) -> None:
        roles = {
            "CLI arm64": "app.ggbond.MacTools.cli",
            "CLI x86_64": "app.ggbond.MacTools.cli",
            "Broker arm64": "app.ggbond.MacTools.cli-broker",
            "Broker x86_64": "app.ggbond.MacTools.cli-broker",
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            plist_path = Path(temporary_directory) / "Info.plist"
            for role, identifier in roles.items():
                expected = {
                    "CFBundleIdentifier": identifier,
                    "CFBundleShortVersionString": "1.2.0",
                    "CFBundleVersion": "69",
                }
                for key, replacement in (
                    ("CFBundleIdentifier", "example.WrongRole"),
                    ("CFBundleShortVersionString", "9.9.9"),
                    ("CFBundleVersion", "999"),
                ):
                    with self.subTest(role=role, key=key):
                        mutated = expected | {key: replacement}
                        with plist_path.open("wb") as stream:
                            plistlib.dump(mutated, stream)
                        result = self.run_binary_validator(
                            "info",
                            "--plist",
                            str(plist_path),
                            "--identifier",
                            identifier,
                            "--version",
                            "1.2.0",
                            "--build",
                            "69",
                            "--role",
                            role,
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(b"identity/version mismatch", result.stderr)

    def test_signing_policy_rejects_role_team_runtime_and_command_failures(self) -> None:
        roles = {
            "Host arm64": "app.ggbond.MacTools",
            "Host x86_64": "app.ggbond.MacTools",
            "CLI arm64": "app.ggbond.MacTools.cli",
            "CLI x86_64": "app.ggbond.MacTools.cli",
            "Broker arm64": "app.ggbond.MacTools.cli-broker",
            "Broker x86_64": "app.ggbond.MacTools.cli-broker",
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            details = Path(temporary_directory) / "signing.txt"
            for role, identifier in roles.items():
                valid_details = (
                    f"Identifier={identifier}\n"
                    "TeamIdentifier=JENNYTEAM\n"
                    "CodeDirectory v=20500 size=1 flags=0x10000(runtime)\n"
                )
                cases = {
                    "valid": valid_details,
                    "identifier": valid_details.replace(identifier, "example.WrongRole"),
                    "team": valid_details.replace("JENNYTEAM", "OTHERTEAM"),
                    "runtime": valid_details.replace("runtime", "adhoc"),
                }
                for mutation, value in cases.items():
                    with self.subTest(role=role, mutation=mutation):
                        details.write_text(value)
                        result = self.run_binary_validator(
                            "signing",
                            "--details",
                            str(details),
                            "--identifier",
                            identifier,
                            "--team",
                            "JENNYTEAM",
                            "--role",
                            role,
                        )
                        if mutation == "valid":
                            self.assertEqual(result.returncode, 0, result.stderr.decode())
                        else:
                            self.assertNotEqual(result.returncode, 0)

        for operation in (
            "App signature verification",
            "CLI signature verification",
            "Broker signature verification",
            "DMG Gatekeeper assessment",
            "CLI Gatekeeper assessment",
        ):
            with self.subTest(operation=operation):
                result = self.run_binary_validator(
                    "status", "--value", "1", "--operation", operation
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(operation.encode(), result.stderr)

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
        binary_policy = BINARY_VALIDATION_SCRIPT.read_text()

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
            'validate_universal_binary "$HOST_PATH" "Host"',
            "--all-architectures",
            '--arch "$architecture"',
            "TeamIdentifier",
            "runtime",
            "validate-release-layout.py",
            "MacToolsCLIBroker",
            "CFBundleIdentifier",
        ):
            self.assertIn(invariant, validator + binary_policy)
        self.assertNotIn("$CLI_PATH version", validator)

    def make_app_layout(self, root: Path) -> Path:
        app = root / "MacTools.app"
        macos = app / "Contents" / "MacOS"
        launch_agents = app / "Contents" / "Library" / "LaunchAgents"
        macos.mkdir(parents=True)
        launch_agents.mkdir(parents=True)
        (macos / "MacTools").touch()
        (macos / "MacToolsCLIBroker").touch()
        service = f"{self.host_identifier}.cli-broker"
        with (launch_agents / "app.ggbond.MacTools.cli-broker.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "Label": service,
                    "BundleProgram": "Contents/MacOS/MacToolsCLIBroker",
                    "MachServices": {service: True},
                    "ProcessType": "Interactive",
                },
                stream,
            )
        return app

    def run_layout_validator(self, app: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(VALIDATE_LAYOUT_SCRIPT),
                "--app",
                str(app),
                "--host-executable",
                "MacTools",
                "--host-identifier",
                self.host_identifier,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_layout_validator_accepts_only_authorized_release_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app_layout(Path(temporary_directory))

            result = self.run_layout_validator(app)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_layout_validator_rejects_any_extra_macos_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app_layout(Path(temporary_directory))
            (app / "Contents" / "MacOS" / "MacToolsCLI").touch()

            result = self.run_layout_validator(app)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unexpected Contents/MacOS entries", result.stderr)

    def test_layout_validator_rejects_symlinked_broker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app_layout(Path(temporary_directory))
            broker = app / "Contents" / "MacOS" / "MacToolsCLIBroker"
            broker.unlink()
            broker.symlink_to("MacTools")

            result = self.run_layout_validator(app)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be a regular file", result.stderr)

    def test_layout_validator_rejects_extra_launch_agent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app_layout(Path(temporary_directory))
            (app / "Contents" / "Library" / "LaunchAgents" / "unexpected.plist").touch()

            result = self.run_layout_validator(app)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unexpected LaunchAgents entries", result.stderr)

    def test_layout_validator_rejects_extra_launch_agent_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app_layout(Path(temporary_directory))
            launch_agent = (
                app
                / "Contents"
                / "Library"
                / "LaunchAgents"
                / "app.ggbond.MacTools.cli-broker.plist"
            )
            with launch_agent.open("rb") as stream:
                value = plistlib.load(stream)
            value["KeepAlive"] = True
            with launch_agent.open("wb") as stream:
                plistlib.dump(value, stream)

            result = self.run_layout_validator(app)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not exactly match", result.stderr)

    def test_checksums_remain_verifiable_after_pair_is_relocated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            destination.mkdir()
            artifact = source / "MacTools.dmg"
            checksum = source / "MacTools.sha256"
            artifact.write_bytes(b"portable release artifact")

            subprocess.run(
                [
                    str(CHECKSUM_SCRIPT),
                    "--artifact",
                    str(artifact),
                    "--output",
                    str(checksum),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            shutil.copy2(artifact, destination / artifact.name)
            shutil.copy2(checksum, destination / checksum.name)

            result = subprocess.run(
                ["/usr/bin/shasum", "-a", "256", "-c", checksum.name],
                cwd=destination,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)

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
