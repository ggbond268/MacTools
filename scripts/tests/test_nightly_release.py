from __future__ import annotations

import importlib.util
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts/nightly-release.py"
SPEC = importlib.util.spec_from_file_location("nightly_release", SCRIPT_PATH)
assert SPEC and SPEC.loader
nightly_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nightly_release)


class NightlyPublicationDecisionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = pathlib.Path(self.temporary_directory.name)
        self.git("init", "--quiet")
        self.previous = self.commit_file("Sources/App.swift", "original source")

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=Nightly Test", "-c", "user.email=nightly@example.invalid",
             "-c", "commit.gpgsign=false", *arguments],
            cwd=self.root, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def commit_file(self, relative_path: str, content: str) -> str:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        self.git("add", "--", relative_path)
        self.git("commit", "--quiet", "-m", "Update fixture")
        return self.git("rev-parse", "HEAD")

    def decide(self, source: str, previous: str | None = None, event: str = "schedule") -> dict:
        return nightly_release.publication_decision(
            event, source, self.previous if previous is None else previous, self.root,
        )

    def test_same_commit_skips_without_repository_writes(self) -> None:
        self.assertEqual(self.decide(self.previous)["decision"], "unchanged")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.previous)

    def test_generated_appcast_and_nested_catalog_changes_do_not_publish(self) -> None:
        self.commit_file("docs/nightly/appcast.xml", "generated feed")
        source = self.commit_file("docs/nightly/plugins/v5/catalog.json", "generated catalog")
        self.assertEqual(self.decide(source)["decision"], "unchanged")

    def test_source_change_publishes_even_alongside_generated_changes(self) -> None:
        self.commit_file("Sources/App.swift", "new source")
        source = self.commit_file("docs/nightly/appcast.xml", "generated feed")
        self.assertEqual(self.decide(source)["decision"], "publish")

    def test_comparison_conservatively_includes_other_repository_inputs(self) -> None:
        for path in ["Plugins/Example/plugin.json", "project.yml", "README.md", "docs/nightly-notes.md"]:
            with self.subTest(path=path):
                source = self.commit_file(path, "changed input")
                self.assertEqual(self.decide(source)["decision"], "publish")
                self.previous = source

    def test_deleted_input_publishes(self) -> None:
        self.git("rm", "Sources/App.swift")
        self.git("commit", "--quiet", "-m", "Delete fixture")
        self.assertEqual(self.decide(self.git("rev-parse", "HEAD"))["decision"], "publish")

    def test_changed_then_reverted_tree_skips(self) -> None:
        self.commit_file("Sources/App.swift", "temporary change")
        source = self.commit_file("Sources/App.swift", "original source")
        self.assertEqual(self.decide(source)["decision"], "unchanged")

    def test_manual_run_always_publishes_including_same_source_and_rollback(self) -> None:
        self.assertEqual(self.decide(self.previous, event="workflow_dispatch")["decision"], "publish")
        newer = self.commit_file("Sources/App.swift", "new source")
        self.assertEqual(
            self.decide(self.previous, previous=newer, event="workflow_dispatch")["decision"],
            "publish",
        )

    def test_first_publish_invalid_previous_source_and_missing_commit_publish(self) -> None:
        for previous in ["", "main", "1234", "0" * 40, "--help"]:
            with self.subTest(previous=previous):
                self.assertEqual(self.decide(self.previous, previous=previous)["decision"], "publish")

    def test_comparison_failure_or_timeout_publishes(self) -> None:
        for error in [OSError("git unavailable"), subprocess.TimeoutExpired("git", 30)]:
            with self.subTest(error=error), mock.patch.object(
                nightly_release.subprocess, "run", side_effect=error,
            ):
                self.assertEqual(self.decide(self.previous)["decision"], "publish")


class NightlyReleaseTests(unittest.TestCase):
    def test_signed_helper_verifier_accepts_only_nightly_identifiers(self) -> None:
        signatures = [
            subprocess.CompletedProcess([], 0, "", f"Identifier=com.example.mactools.plugins.{plugin}.smc-helper.nightly\n")
            for plugin in ["fan-control", "battery-charge-limit"]
        ]
        with mock.patch.object(nightly_release.subprocess, "run", side_effect=signatures) as inspect:
            nightly_release.verify_nightly_helper_signatures(pathlib.Path("Packages"), "com.example")
        self.assertEqual(inspect.call_count, 2)
        self.assertIn("FanControl.bundle/Contents/Resources/SMCHelper/mactools-fan-smc-helper", inspect.call_args_list[0].args[0][-1])
        self.assertIn("BatteryChargeLimit.bundle/Contents/Resources/SMCHelper/mactools-battery-smc-helper", inspect.call_args_list[1].args[0][-1])

    def test_signed_helper_verifier_rejects_stable_or_missing_signatures(self) -> None:
        for identifier in ["mactools-fan-smc-helper", "com.example.mactools.plugins.fan-control.smc-helper", ""]:
            with self.subTest(identifier=identifier), mock.patch.object(
                nightly_release.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, "", f"Identifier={identifier}\n"),
            ), self.assertRaises(SystemExit):
                nightly_release.verify_nightly_helper_signatures(pathlib.Path("Packages"), "com.example")
        with mock.patch.object(nightly_release.subprocess, "run", side_effect=OSError("missing helper")), self.assertRaises(SystemExit):
            nightly_release.verify_nightly_helper_signatures(pathlib.Path("Packages"), "com.example")

    def test_metadata_uses_run_attempt_for_monotonic_retries(self) -> None:
        metadata = nightly_release.make_metadata(
            config_path=REPO_ROOT / "Configs/AppVersion.xcconfig",
            plugins_dir=REPO_ROOT / "Plugins",
            repository="ggbond268/MacTools",
            source_sha="a" * 40,
            run_number="512",
            run_attempt="3",
        )

        self.assertEqual(metadata["BUILD_NUMBER"], "512.3")
        self.assertEqual(metadata["TAG"], "nightly-512-3")
        self.assertNotIn("PROJECT_NAME", metadata)
        self.assertEqual(metadata["PLUGIN_KIT_VERSION"], "5")
        self.assertEqual(
            metadata["NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH"],
            "docs/nightly/plugins/v5/catalog.json",
        )

    def test_release_warning_is_first(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "notes.md"
            nightly_release.write_release_notes(
                output,
                "example/MacTools",
                "1.2.1",
                "512.1",
                "a" * 40,
            )
            notes = output.read_text(encoding="utf-8")

            self.assertTrue(notes.startswith("> [!WARNING]\n"))
            self.assertIn("MacTools Nightly is unstable", notes)
            self.assertIn("Signed assets for an existing Nightly tag are never replaced", notes)
            self.assertIn("github.com/example/MacTools/commit/", notes)

    def test_appcast_uses_dedicated_asset_and_numeric_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "appcast.xml"
            nightly_release.write_appcast(
                output_path=output,
                repository="example/MacTools",
                tag="nightly-512-1",
                version="1.2.1",
                build_number="512.1",
                signature="signature",
                file_size=1234,
                publication_date="Tue, 25 Aug 2026 12:00:00 +0000",
                release_notes="> [!WARNING]\n> Unstable",
            )
            content = output.read_text(encoding="utf-8")

            self.assertIn("<sparkle:version>512.1</sparkle:version>", content)
            self.assertIn("nightly-512-1/MacTools-Nightly.dmg", content)
            self.assertNotIn("docs/appcast.xml", content)

            self.assertEqual(
                nightly_release.read_nightly_appcast_tag(output),
                "nightly-512-1",
            )

    def test_verify_app_accepts_fully_isolated_nightly_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = pathlib.Path(temporary_directory) / "MacTools Nightly.app"
            app_info_path = app / "Contents/Info.plist"
            extension_info_path = (
                app
                / "Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
            )
            extension_info_path.parent.mkdir(parents=True)
            app_info = {
                "CFBundleDisplayName": "MacTools Nightly",
                "CFBundleIdentifier": "com.example.mactools.nightly",
                "CFBundleShortVersionString": "1.2.1",
                "CFBundleVersion": "512.1",
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mactools-nightly"]}],
                "MTApplicationSupportDirectoryName": "MacTools Nightly",
                "MTReleaseChannel": "nightly",
                "MTPluginCatalogURL": "https://mactools.ggbond.app/nightly/plugins/v6/catalog.json",
                "MTRightClickConfigurationHomeRelativePath": "Library/Application Support/MacTools Nightly/right-click-menu.json",
                "SUFeedURL": "https://mactools.ggbond.app/nightly/appcast.xml",
            }
            extension_info = {
                "CFBundleDisplayName": "MacTools Nightly 右键工具",
                "CFBundleIdentifier": "com.example.mactools.nightly.right-click.finder-sync",
                "CFBundleShortVersionString": "1.2.1",
                "CFBundleVersion": "512.1",
                "MTRightClickHostURLScheme": "mactools-nightly",
                "MTRightClickToolbarItemName": "MacTools Nightly",
                "MTRightClickConfigurationHomeRelativePath": "Library/Application Support/MacTools Nightly/right-click-menu.json",
            }
            with app_info_path.open("wb") as file:
                plistlib.dump(app_info, file)
            with extension_info_path.open("wb") as file:
                plistlib.dump(extension_info, file)

            with mock.patch.object(nightly_release, "verify_nightly_cli") as verify_cli:
                nightly_release.verify_nightly_app(app, "com.example", "1.2.1", "512.1", 6)
            verify_cli.assert_called_once_with(app, "com.example", None, False)

    def test_appcast_tag_rejects_malformed_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            appcast = pathlib.Path(temporary_directory) / "appcast.xml"
            appcast.write_text("<html>not an appcast", encoding="utf-8")

            with self.assertRaises(SystemExit):
                nightly_release.read_nightly_appcast_tag(appcast)

    def test_catalog_requires_all_plugins_and_build_specific_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            plugins = root / "Plugins"
            plugin = plugins / "Example"
            plugin.mkdir(parents=True)
            (plugin / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example",
                        "version": "1.4.2",
                        "pluginKitVersion": 5,
                        "minHostVersion": "1.2.0",
                    }
                ),
                encoding="utf-8",
            )
            catalog_path = root / "catalog.json"
            catalog_path.write_text(
                json.dumps(
                    {
                        "signature": {"algorithm": "ed25519", "value": "signed"},
                        "plugins": [
                            {
                                "id": "example",
                                "version": "1.512.1",
                                "pluginKitVersion": 5,
                                "package": {
                                    "url": "https://github.com/example/MacTools/releases/download/nightly-512-1/example.mactoolsplugin.zip"
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            nightly_release.verify_nightly_catalog(
                catalog_path,
                plugins,
                "example/MacTools",
                "nightly-512-1",
                "512.1",
            )

    def test_retention_only_selects_old_matching_prereleases(self) -> None:
        releases = [
            {
                "tagName": f"nightly-{index}-1",
                "isPrerelease": True,
                "publishedAt": f"2026-08-{index:02d}T00:00:00Z",
            }
            for index in range(1, 5)
        ]
        releases.extend(
            [
                {
                    "tagName": "v1.2.0",
                    "isPrerelease": False,
                    "publishedAt": "2026-08-20T00:00:00Z",
                },
                {
                    "tagName": "beta-manual",
                    "isPrerelease": True,
                    "publishedAt": "2026-08-21T00:00:00Z",
                },
                {
                    "tagName": "nightly-99-1",
                    "isDraft": True,
                    "isPrerelease": True,
                    "publishedAt": None,
                },
            ]
        )

        self.assertEqual(
            nightly_release.stale_nightly_tags(releases, keep=2),
            ["nightly-2-1", "nightly-1-1"],
        )
        self.assertEqual(
            nightly_release.stale_nightly_tags(
                releases,
                keep=2,
                preserve_tags=["nightly-1-1"],
            ),
            ["nightly-2-1"],
        )

    def test_retention_never_deletes_the_advertised_tag(self) -> None:
        advertised_tag = "nightly-100-1"
        releases = [
            {
                "tagName": advertised_tag,
                "isPrerelease": True,
                "publishedAt": "2026-08-01T00:00:00Z",
            }
        ]
        releases.extend(
            {
                "tagName": f"nightly-{100 + index}-1",
                "isPrerelease": True,
                "publishedAt": f"2026-08-{index + 1:02d}T00:00:00Z",
            }
            for index in range(1, 15)
        )

        self.assertEqual(
            nightly_release.stale_nightly_tags(
                releases,
                keep=14,
                preserve_tags=[advertised_tag],
            ),
            [],
        )


class NightlyCLIVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "MacTools Nightly.app"
        self.broker = self.app / "Contents/MacOS/MacToolsCLIBroker"
        self.broker.parent.mkdir(parents=True)
        self.broker.touch()
        self.cli = self.root / "mactools"
        self.cli.touch()
        self.identifier = "com.example.mactools.nightly.cli-broker"
        self.agent_path = self.app / "Contents/Library/LaunchAgents/app.ggbond.MacTools.cli-broker.plist"
        self.agent_path.parent.mkdir(parents=True)
        self.agent = {
            "Label": self.identifier,
            "MachServices": {self.identifier: True},
            "BundleProgram": "Contents/MacOS/MacToolsCLIBroker",
        }
        self.write_agent()

    def write_agent(self) -> None:
        with self.agent_path.open("wb") as file:
            plistlib.dump(self.agent, file)

    def test_accepts_matching_unsigned_broker_and_standalone_cli(self) -> None:
        with mock.patch.object(nightly_release, "executable_bundle_identifier", side_effect=[
            self.identifier, "com.example.mactools.nightly.cli",
        ]) as read_identifier:
            nightly_release.verify_nightly_cli(self.app, "com.example", self.cli)
        self.assertEqual(read_identifier.call_args_list, [mock.call(self.broker), mock.call(self.cli)])

    def test_rejects_stable_or_development_executable_identity(self) -> None:
        for host in ["com.example.mactools", "com.example.mactools.dev"]:
            for values in [[host + ".cli-broker"], [self.identifier, host + ".cli"]]:
                with self.subTest(values=values), mock.patch.object(
                    nightly_release, "executable_bundle_identifier", side_effect=values,
                ), self.assertRaisesRegex(SystemExit, "must embed"):
                    nightly_release.verify_nightly_cli(self.app, "com.example", self.cli)

    def test_rejects_unisolated_launch_agent_values(self) -> None:
        for key, incorrect in [
            ("Label", "com.example.mactools.cli-broker"),
            ("MachServices", {"com.example.mactools.cli-broker": True}),
            ("BundleProgram", "/Applications/MacTools.app/Contents/MacOS/MacToolsCLIBroker"),
        ]:
            original = self.agent[key]
            self.agent[key] = incorrect
            self.write_agent()
            with self.subTest(key=key), self.assertRaisesRegex(SystemExit, "not isolated"):
                nightly_release.verify_nightly_cli(self.app, "com.example")
            self.agent[key] = original

    def test_rejects_missing_broker_and_missing_agent(self) -> None:
        self.broker.unlink()
        with self.assertRaisesRegex(SystemExit, "must embed"):
            nightly_release.verify_nightly_cli(self.app, "com.example")
        self.agent_path.unlink()
        with self.assertRaisesRegex(SystemExit, "LaunchAgent is missing"):
            nightly_release.verify_nightly_cli(self.app, "com.example")

    def test_signed_verification_rejects_mismatched_signing_identifier(self) -> None:
        with mock.patch.object(nightly_release, "executable_bundle_identifier", return_value=self.identifier):
            for identifier in [self.identifier, "com.example.mactools.cli-broker"]:
                with mock.patch.object(nightly_release.subprocess, "run", return_value=mock.Mock(
                    stderr=f"Identifier={identifier}\n",
                )):
                    if identifier == self.identifier:
                        nightly_release.verify_nightly_cli(self.app, "com.example", signed=True)
                    else:
                        with self.assertRaisesRegex(SystemExit, "signing identifier"):
                            nightly_release.verify_nightly_cli(self.app, "com.example", signed=True)

    def test_embedded_info_probe_passes_executable_path_as_data(self) -> None:
        path = pathlib.Path("/tmp/a quoted ' path/mactools")
        with mock.patch.object(nightly_release.subprocess, "run", return_value=mock.Mock(
            stdout=self.identifier + "\n",
        )) as run:
            self.assertEqual(nightly_release.executable_bundle_identifier(path), self.identifier)
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[-1], str(path))
        self.assertNotIn(str(path), arguments[-2])


if __name__ == "__main__":
    unittest.main()
