import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class NightlyConfigurationTests(unittest.TestCase):
    def test_project_declares_isolated_release_optimized_nightly_configuration(self) -> None:
        project = (REPO_ROOT / "project.yml").read_text(encoding="utf-8")

        self.assertIn("Nightly: release", project)
        self.assertIn('PRODUCT_NAME: "MacTools Nightly"', project)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_IDENTIFIER_PREFIX).mactools.nightly"', project)
        self.assertIn("MACTOOLS_URL_SCHEME: mactools-nightly", project)
        self.assertIn('APPLICATION_SUPPORT_DIRECTORY_NAME: "MacTools Nightly"', project)
        self.assertIn("https://mactools.ggbond.app/nightly/appcast.xml", project)
        self.assertNotIn("https://mactools.ggbond.app/nightly/plugins/v5/catalog.json", project)
        self.assertNotIn(
            "MACTOOLS_RELEASE_CHANNEL: stable\n        PLUGIN_CATALOG_URL:",
            project,
        )
        self.assertIn("RIGHT_CLICK_EXTENSION_DISPLAY_NAME: MacTools Nightly 右键工具", project)
        self.assertIn("RIGHT_CLICK_TOOLBAR_ITEM_NAME: MacTools Nightly", project)

    def test_finder_sync_nightly_entitlement_isolated_from_stable_and_debug(self) -> None:
        entitlement_path = (
            REPO_ROOT
            / "Sources/Extensions/RightClickFinderSync/RightClickFinderSync-Nightly.entitlements"
        )
        with entitlement_path.open("rb") as file:
            entitlements = plistlib.load(file)

        paths = entitlements[
            "com.apple.security.temporary-exception.files.home-relative-path.read-only"
        ]
        self.assertEqual(
            paths,
            ["/Library/Application Support/MacTools Nightly/right-click-menu.json"],
        )

    def test_cli_and_broker_use_matching_nightly_identities_and_release_settings(self) -> None:
        project = (REPO_ROOT / "project.yml").read_text(encoding="utf-8")
        for target, suffix in [("MacToolsCLI", "cli"), ("MacToolsCLIBroker", "cli-broker")]:
            # A target ends at the next two-space key, not at its indented settings.
            block = re.split(r"^  \S", project.split(f"  {target}:\n", 1)[1], maxsplit=1, flags=re.MULTILINE)[0]
            self.assertIn("Nightly: Configs/AppNightly.xcconfig", block)
            nightly = block.split("        Nightly:\n", 1)[1].split("        Release:\n", 1)[0]
            self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_IDENTIFIER_PREFIX).mactools.nightly.{suffix}"', nightly)
            self.assertIn("DEAD_CODE_STRIPPING: true", nightly)
            self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_IDENTIFIER_PREFIX).mactools.{suffix}"', block)

    def test_nightly_workflow_signs_and_verifies_embedded_broker(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        signing = workflow.split("- name: Sign app bundle", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('CLI_BROKER="$APP_PATH/Contents/MacOS/MacToolsCLIBroker"', signing)
        self.assertLess(signing.index('sign_path "$CLI_BROKER"'), signing.index('"$APP_PATH" --signed'))
        self.assertIn('--app "$APP_PATH" --signed', signing)
        for name in ["nightly.yml", "build.yml"]:
            self.assertRegex((REPO_ROOT / ".github/workflows" / name).read_text(), r'--cli "[^\n]+/Nightly/mactools"')

    def test_generated_plugin_targets_map_nightly_to_release_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = pathlib.Path(temporary_directory) / "GeneratedPlugins.yml"
            subprocess.run(
                [
                    str(REPO_ROOT / "scripts/plugins/generate-plugin-project-config.rb"),
                    "--source-dir", str(REPO_ROOT / "Plugins"),
                    "--output", str(output),
                ],
                check=True,
            )
            generated = output.read_text(encoding="utf-8")

        self.assertIn("Nightly: Release.xcconfig", generated)
        self.assertIn(
            "$(BUILT_PRODUCTS_DIR)/MacTools Nightly.app/Contents/MacOS/MacTools Nightly",
            generated,
        )

    def test_pull_request_ci_builds_and_verifies_nightly(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")

        self.assertIn("Build and verify unsigned Nightly configuration", workflow)
        self.assertIn("-configuration Nightly", workflow)
        self.assertIn("scripts/nightly-release.py verify-app", workflow)
        self.assertIn("scripts/nightly-release.py plugin-kit-version", workflow)
        self.assertIn('--plugin-kit-version "$PLUGIN_KIT_VERSION"', workflow)
        self.assertIn(
            'PLUGIN_CATALOG_URL="https://mactools.ggbond.app/nightly/plugins/v${PLUGIN_KIT_VERSION}/catalog.json"',
            workflow,
        )

    def test_nightly_helpers_embed_distinct_signing_identifiers_without_changing_stable(self) -> None:
        for directory, plugin_id in [("FanControl", "fan-control"), ("BatteryChargeLimit", "battery-charge-limit")]:
            with self.subTest(plugin=plugin_id):
                fragment = (REPO_ROOT / "Plugins" / directory / "project.yml").read_text(encoding="utf-8")
                base, nightly = fragment.split("      configs:\n        Nightly:\n")
                identifier = f"$(BUNDLE_IDENTIFIER_PREFIX).mactools.plugins.{plugin_id}.smc-helper"
                self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER: "{identifier}"', base)
                self.assertIn("configFiles:\n      Nightly: Release.xcconfig", base)
                self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER: "{identifier}.nightly"', nightly)
                self.assertIn("CREATE_INFOPLIST_SECTION_IN_BINARY: true", nightly)
                self.assertNotIn("CREATE_INFOPLIST_SECTION_IN_BINARY", base)

    def test_single_job_gate_guards_every_release_step_before_credentials(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        jobs = workflow.split("jobs:\n", 1)[1]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", jobs, re.MULTILINE), ["release"])
        self.assertLess(workflow.index("id: nightly_gate"), workflow.index("Validate required secrets"))
        steps = re.split(r"^      - name: ", workflow, flags=re.MULTILINE)[1:]
        for step in steps:
            name = step.splitlines()[0]
            with self.subTest(step=name):
                if name in ["Checkout selected source", "Set Nightly metadata", "Decide whether to publish Nightly"]:
                    continue
                if name == "Report unchanged Nightly":
                    self.assertIn("if: steps.nightly_gate.outputs.decision == 'unchanged'", step)
                elif name == "Cleanup keychain":
                    self.assertIn("if: always() && steps.nightly_gate.outputs.decision == 'publish'", step)
                else:
                    self.assertIn("if: steps.nightly_gate.outputs.decision == 'publish'", step)

    def test_gate_reads_advertised_release_and_manual_runs_bypass_lookup(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        gate = workflow.split("- name: Decide whether to publish Nightly", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('if [[ "$GITHUB_EVENT_NAME" == "schedule" ]]', gate)
        self.assertIn("https://mactools.ggbond.app/nightly/appcast.xml", gate)
        self.assertIn('gh release view "$PREVIOUS_TAG"', gate)
        self.assertIn("--json targetCommitish,isDraft,isPrerelease", gate)
        self.assertIn('.isDraft == false and .isPrerelease == true', gate)
        self.assertIn('|| PREVIOUS_SOURCE_SHA=""', gate)
        self.assertNotIn("releases/latest", gate)
        self.assertNotIn("git commit", gate)

    def test_gate_shell_handles_manual_unchanged_and_indeterminate_publication(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        gate = workflow.split("- name: Decide whether to publish Nightly", 1)[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(gate.split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / "source.swift").write_text("source", encoding="utf-8")
            subprocess.run(["git", "add", "source.swift"], cwd=root, check=True)
            subprocess.run([
                "git", "-c", "user.name=Nightly Test", "-c", "user.email=nightly@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture",
            ], cwd=root, check=True)
            source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / "scripts").mkdir()
            (root / "scripts/nightly-release.py").symlink_to(REPO_ROOT / "scripts/nightly-release.py")
            binaries = root / "bin"
            binaries.mkdir()
            stubs = {
                "curl": 'echo curl >> "$MOCK_LOG"\n[[ "$MOCK_MODE" != "curl-failure" ]] || exit 22\ncp "$MOCK_APPCAST" "${@: -1}"\n',
                "gh": 'printf "%s\\n" "$*" >> "$MOCK_LOG"\n[[ "$MOCK_MODE" != "release-failure" ]] || exit 1\nprintf "%s\\n" "$MOCK_SOURCE"\n',
            }
            for name, body in stubs.items():
                executable = binaries / name
                executable.write_text("#!/bin/bash\nset -eu\n" + body, encoding="utf-8")
                executable.chmod(0o755)

            scenarios = [
                ("workflow_dispatch", "normal", "publish"),
                ("schedule", "normal", "unchanged"),
                ("schedule", "curl-failure", "publish"),
                ("schedule", "malformed-feed", "publish"),
                ("schedule", "release-failure", "publish"),
                ("schedule", "unusable-source", "publish"),
            ]
            for index, (event, mode, expected) in enumerate(scenarios):
                with self.subTest(event=event, mode=mode):
                    run = root / str(index)
                    run.mkdir()
                    appcast = run / "feed.xml"
                    appcast.write_text(
                        "not XML" if mode == "malformed-feed" else
                        '<rss><channel><item><enclosure url="https://github.com/example/MacTools/releases/download/nightly-12-1/MacTools-Nightly.dmg" /></item></channel></rss>',
                        encoding="utf-8",
                    )
                    output = run / "output"
                    log = run / "network-log"
                    environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                        GITHUB_EVENT_NAME=event, GITHUB_REPOSITORY="example/MacTools",
                        GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(run / "summary"),
                        RUNNER_TEMP=str(run), SOURCE_SHA=source, MOCK_MODE=mode,
                        MOCK_SOURCE="main" if mode == "unusable-source" else source,
                        MOCK_APPCAST=str(appcast), MOCK_LOG=str(log))
                    if event == "workflow_dispatch":
                        # A rollback can check out a script that predates the new gate command.
                        (root / "scripts/nightly-release.py").unlink()
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                        cwd=root, env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"decision={expected}\n", output.read_text(encoding="utf-8"))
                    if event == "workflow_dispatch":
                        self.assertFalse(log.exists(), "Manual runs must not depend on previous publication metadata")
                        (root / "scripts/nightly-release.py").symlink_to(REPO_ROOT / "scripts/nightly-release.py")
                    elif mode == "normal":
                        self.assertIn("release view nightly-12-1 --repo example/MacTools", log.read_text(encoding="utf-8"))

    def test_nightly_workflow_is_gated_manual_and_fail_closed(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")

        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        self.assertIn("vars.ENABLE_NIGHTLY_RELEASES == 'true'", workflow)
        self.assertIn('git merge-base --is-ancestor "$SOURCE_SHA" origin/main', workflow)
        self.assertIn("refusing to expose release credentials", workflow)
        self.assertIn("--draft", workflow)
        self.assertIn("--latest=false", workflow)
        self.assertNotIn("--clobber", workflow)
        self.assertLess(
            workflow.index("gh release edit"),
            workflow.index("Publish dedicated Nightly catalog and appcast last"),
        )
        self.assertIn("docs/appcast.xml", workflow)
        self.assertIn("git diff --exit-code", workflow)
        self.assertIn("NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH", workflow)
        self.assertIn("NIGHTLY_APPCAST_RELATIVE_PATH", workflow)
        self.assertIn("unexpected publication state", workflow)
        self.assertIn("unexpectedly replaced the stable Latest release", workflow)
        self.assertIn("preflight-app-plugin-catalog.swift", workflow)
        self.assertIn("scripts/nightly-release.py verify-helper-signatures", workflow)
        self.assertIn('--deployed-catalog "$SIGNED_PLUGIN_CATALOG_PATH"', workflow)
        self.assertIn(
            '(cd "$DMG_DIRECTORY" && shasum -a 256 "$DMG_NAME")',
            workflow,
        )
        self.assertIn("gh api --paginate --slurp", workflow)
        self.assertNotIn("--slurp \\\n            --jq", workflow)
        self.assertIn("jq 'flatten | map(", workflow)
        self.assertIn('--preserve-tag "$COMMITTED_TAG"', workflow)
        self.assertIn('--preserve-tag "$DEPLOYED_TAG"', workflow)
        self.assertIn('&& DEPLOYED_TAG="$(scripts/nightly-release.py appcast-tag', workflow)

    def test_nightly_reuses_existing_release_credentials(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")

        for secret in [
            "DEVELOPER_ID_CERT_P12",
            "ASC_API_KEY_P8_BASE64",
            "SPARKLE_PRIVATE_KEY",
            "PLUGIN_CATALOG_PRIVATE_KEY_BASE64",
        ]:
            self.assertIn(f"secrets.{secret}", workflow)
        self.assertNotIn("NIGHTLY_SPARKLE_PRIVATE_KEY", workflow)

    def test_pages_deploy_waits_for_successful_nightly_workflow(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")

        self.assertIn('- "docs/nightly/**"', workflow)
        self.assertIn("- Nightly", workflow)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)


if __name__ == "__main__":
    unittest.main()
