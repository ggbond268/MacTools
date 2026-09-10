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
        self.assertLess(signing.index('sign_path "$CLI_BROKER"'), signing.index('--app "$APP_PATH"'))
        self.assertIn('CLI_PATH="$DERIVED_DATA/Build/Products/Nightly/mactools"', signing)
        self.assertLess(signing.index('sign_path "$CLI_PATH"'), signing.index('--app "$APP_PATH"'))
        self.assertIn('--app "$APP_PATH" --cli "$CLI_PATH" --signed', signing)
        for name in ["nightly.yml", "build.yml"]:
            self.assertRegex((REPO_ROOT / ".github/workflows" / name).read_text(), r'--cli "[^\n]+/Nightly/mactools"')

    def test_nightly_workflow_packages_notarizes_verifies_and_publishes_cli(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        build = workflow.split("- name: Build unsigned Nightly app and plugins", 1)[1].split("\n      - name:", 1)[0]
        prepare_cli = workflow.split("- name: Prepare arm64 Nightly CLI", 1)[1].split("\n      - name:", 1)[0]
        certificate = workflow.split("- name: Import Developer ID certificate", 1)[1].split("\n      - name:", 1)[0]
        package = workflow.split("- name: Sign app bundle", 1)[1].split("\n      - name:", 1)[0]
        notarize = workflow.split("- name: Notarize Nightly app and CLI distributions", 1)[1].split("\n      - name:", 1)[0]
        keychain_cleanup = workflow.split("- name: Remove release signing keychain before appcast signing", 1)[1].split("\n      - name:", 1)[0]
        checksums = workflow.split("- name: Generate Nightly notes, checksums, and statically verify CLI", 1)[1].split("\n      - name:", 1)[0]
        appcast = workflow.split("- name: Generate signed Nightly appcast", 1)[1].split("\n      - name:", 1)[0]
        candidate = workflow.split("- name: Upload immutable Nightly candidate", 1)[1].split("\n      - name:", 1)[0]
        execution = workflow.split("- name: Verify and execute archived CLI", 1)[1].split("\n\n  publish:", 1)[0]
        publication = workflow.split("- name: Upload and publish verified Nightly assets", 1)[1].split("\n      - name:", 1)[0]

        self.assertNotIn("ARCHS=arm64", build)
        self.assertIn('/usr/bin/lipo "$CLI_PATH" -thin arm64', prepare_cli)
        self.assertIn('[[ "$(/usr/bin/lipo -archs "$CLI_PATH")" == "arm64" ]]', prepare_cli)
        self.assertIn("umask 077", certificate)
        self.assertIn("trap 'rm -f \"$CERT_PATH\"' EXIT", certificate)
        self.assertLess(certificate.index('echo "KEYCHAIN_PATH=$KEYCHAIN_PATH"'), certificate.index("security create-keychain"))
        self.assertIn("scripts/nightly-release.py package-cli", package)
        self.assertIn('--output "$CLI_ARCHIVE_PATH"', package)
        self.assertIn('notarytool submit "$artifact"', notarize)
        self.assertIn('notarize_and_require_accepted "$CLI_ARCHIVE_PATH"', notarize)
        self.assertGreaterEqual(notarize.count("--output-format json"), 1)
        self.assertIn("scripts/nightly-release.py verify-notarization", notarize)
        self.assertIn("notarytool log", notarize)
        self.assertIn("umask 077", notarize)
        self.assertIn("trap 'rm -f \"$API_KEY_PATH\"' EXIT", notarize)
        self.assertIn('security delete-keychain "$KEYCHAIN_PATH"', keychain_cleanup)
        self.assertIn('shasum -a 256 "$CLI_NAME"', checksums)
        self.assertIn("scripts/nightly-release.py verify-cli-archive", checksums)
        self.assertIn("--skip-execution", checksums)
        self.assertIn('--team-identifier "${{ secrets.APPLE_DEVELOPMENT_TEAM }}"', checksums)
        self.assertNotIn("SPARKLE_PRIVATE_KEY", checksums)
        self.assertIn("scripts/nightly-release.py verify-cli-archive", execution)
        self.assertNotIn("--skip-execution", execution)
        self.assertNotIn("secrets.", execution)
        self.assertIn("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}", appcast)
        self.assertIn("umask 077", appcast)
        self.assertIn("trap 'rm -f \"$SPARKLE_KEY_PATH\"' EXIT", appcast)
        self.assertLess(workflow.index("Remove release signing keychain before appcast signing"), workflow.index("--skip-execution"))
        for variable in ["CLI_ARCHIVE_PATH", "CLI_SHA256_PATH"]:
            self.assertIn(f'"${variable}"', publication)
            self.assertIn(f'${{{{ env.{variable} }}}}', candidate)
        for path in ["nightly-release-notes.md", "nightly-appcast.xml", "cli-verification-context.json"]:
            self.assertIn(path, candidate)

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

    def test_ci_workflows_use_their_configured_build_products_and_have_sufficient_timeout(self) -> None:
        build_workflow = (REPO_ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        nightly_workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")

        self.assertIn("timeout-minutes: 60", build_workflow)
        self.assertIn(
            './scripts/plugins/verify-plugin-kit-v6-binary-compatibility.sh \\\n'
            '            "$DERIVED_DATA/Build/Products/Debug"',
            nightly_workflow,
        )

    def test_nightly_plugin_builder_accepts_an_empty_filter_list_on_system_bash(self) -> None:
        script = (REPO_ROOT / "scripts/plugins/build-plugin-release-assets.sh").read_text(encoding="utf-8")

        self.assertIn('for plugin_filter in "${PLUGIN_FILTERS[@]-}"; do', script)
        self.assertIn('[[ -n "$plugin_filter" ]] || continue', script)

    def test_nightly_catalog_uses_the_schema_generators_compatibility_floor(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        builder = (REPO_ROOT / "scripts/plugins/build-plugin-release-assets.sh").read_text(encoding="utf-8")

        self.assertNotIn("PLUGIN_CATALOG_MINIMUM_HOST_VERSION", workflow)
        self.assertIn('catalog_args+=(--nightly-build-number "$NIGHTLY_BUILD_NUMBER")', builder)

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

    def test_nightly_jobs_isolate_cli_execution_and_repository_credentials(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        jobs = workflow.split("jobs:\n", 1)[1]
        self.assertEqual(
            re.findall(r"^  ([a-z_]+):", jobs, re.MULTILINE),
            ["build", "verify_cli", "publish"],
        )
        self.assertLess(workflow.index("id: nightly_gate"), workflow.index("Validate required secrets"))
        build, remainder = jobs.split("\n  verify_cli:\n", 1)
        verification, publication = remainder.split("\n  publish:\n", 1)
        self.assertIn("--skip-execution", build)
        self.assertNotIn("Verify and execute archived CLI", build)
        self.assertIn("Verify and execute archived CLI", verification)
        self.assertNotIn("--skip-execution", verification)
        self.assertNotIn("secrets.", verification)
        self.assertNotIn("GH_TOKEN", verification)
        self.assertIn("permissions:\n      contents: read", verification)
        self.assertIn("needs: [build, verify_cli]", publication)
        self.assertIn("permissions:\n      contents: write", publication)
        self.assertNotIn("verify-cli-archive", publication)
        self.assertEqual(workflow.count("persist-credentials: false"), 3)
        self.assertNotIn("persist-credentials: true", workflow)
        artifact_name = "MacTools-Nightly-${{ github.run_number }}.${{ github.run_attempt }}"
        self.assertEqual(workflow.count(f"name: {artifact_name}"), 1)
        self.assertEqual(workflow.count("uses: actions/upload-artifact@v4"), 1)
        self.assertEqual(workflow.count("uses: actions/download-artifact@v5"), 2)

    def test_nightly_retries_preserve_the_producing_build_candidate(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        jobs = dict(re.findall(
            r"^  (build|verify_cli|publish):\n(.*?)(?=^  \w+:\n|\Z)",
            workflow, re.MULTILINE | re.DOTALL,
        ))

        def step(job: str, name: str) -> str:
            return jobs[job].split(f"- name: {name}\n", 1)[1].split("\n      - name:", 1)[0]

        def render(value: str, context: dict[str, str]) -> str:
            return re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda match: context[match[1]], value)

        def run_metadata(job: str, attempt: int, context: dict[str, str]) -> tuple[dict, dict]:
            metadata_step = render(step(job, "Set Nightly metadata"), context)
            with tempfile.TemporaryDirectory() as temporary_directory:
                root = pathlib.Path(temporary_directory)
                environment = dict(
                    os.environ,
                    GITHUB_ENV=str(root / "env"), GITHUB_OUTPUT=str(root / "output"),
                    GITHUB_RUN_NUMBER="512", GITHUB_RUN_ATTEMPT=str(attempt),
                    GITHUB_REPOSITORY="ggbond268/MacTools", SOURCE_SHA="a" * 40,
                )
                if "        env:\n" in metadata_step:
                    environment.update(re.findall(
                        r"^          ([A-Z_]+): (.+)$",
                        metadata_step.split("        run: |\n", 1)[0], re.MULTILINE,
                    ))
                script = textwrap.dedent(metadata_step.split("        run: |\n", 1)[1])
                result = subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", script],
                    cwd=REPO_ROOT, env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

                def values(name: str) -> dict[str, str]:
                    path = root / name
                    return dict(line.split("=", 1) for line in path.read_text().splitlines()) if path.exists() else {}

                return values("env"), values("output")

        build_outputs = jobs["build"].split("    outputs:\n", 1)[1].split("\n    steps:", 1)[0]
        metadata_id = re.search(r"^        id: (\w+)$", step("build", "Set Nightly metadata"), re.MULTILINE)[1]
        upload_id = re.search(r"^        id: (\w+)$", step("build", "Upload immutable Nightly candidate"), re.MULTILINE)[1]
        for build_attempt, retry_attempt in [(1, 1), (1, 2), (1, 3), (2, 2), (2, 3)]:
            with self.subTest(build_attempt=build_attempt, retry_attempt=retry_attempt):
                built, outputs = run_metadata("build", build_attempt, {})
                artifact_id = str(9000 + build_attempt)
                context = {
                    "steps.nightly_gate.outputs.decision": "publish",
                    "steps.selected_source.outputs.source_sha": "a" * 40,
                    f"steps.{upload_id}.outputs.artifact-id": artifact_id,
                    **{f"steps.{metadata_id}.outputs.{key}": value for key, value in outputs.items()},
                }
                context.update({
                    f"needs.build.outputs.{key}": render(value, context)
                    for key, value in re.findall(r"^      (\w+): (.+)$", build_outputs, re.MULTILINE)
                })
                self.assertEqual(built["BUILD_NUMBER"], f"512.{build_attempt}")
                for job in ("verify_cli", "publish"):
                    with self.subTest(job=job):
                        metadata, _ = run_metadata(job, retry_attempt, context)
                        self.assertEqual(metadata, built)
                        download = jobs[job].split("uses: actions/download-artifact@v5\n", 1)[1].split("\n      - name:", 1)[0]
                        resolved = render(download, {**context, **{f"env.{key}": value for key, value in metadata.items()}})
                        inputs = dict(re.findall(r"^          ([\w-]+): (.+)$", resolved, re.MULTILINE))
                        self.assertEqual(inputs["artifact-ids"], artifact_id)
                        self.assertNotIn("name", inputs)
                        self.assertEqual(inputs["path"], built["ARTIFACT_ROOT"])

    def test_selected_source_interface_gate_accepts_only_complete_current_interface(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        required_interface = re.search(
            r"^  NIGHTLY_RELEASE_INTERFACE_VERSION: (\d+)$", workflow, re.MULTILINE,
        ).group(1)
        declared_interface = subprocess.check_output(
            [str(REPO_ROOT / "scripts/nightly-release.py"), "release-interface-version"],
            text=True,
        ).strip()
        self.assertEqual(required_interface, declared_interface)
        validation = workflow.split(
            "- name: Validate selected source release interface", 1,
        )[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(validation.split("        run: |\n", 1)[1])

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            scripts = root / "scripts"
            guide = root / "docs/testing/cli-nightly-distribution.md"
            binaries = root / "bin"
            scripts.mkdir(parents=True)
            binaries.mkdir()

            git = binaries / "git"
            git.write_text(
                "#!/bin/bash\n"
                "set -eu\n"
                "if [[ \"$1 $2\" == \"rev-parse HEAD\" ]]; then printf '%s\\n' \"$MOCK_SOURCE_SHA\"; fi\n",
                encoding="utf-8",
            )
            git.chmod(0o755)

            interface = scripts / "nightly-release.py"
            interface.write_text(
                "#!/bin/bash\n"
                "set -eu\n"
                "[[ \"$MOCK_INTERFACE\" != absent ]] || exit 2\n"
                "printf '%s\\n' \"$MOCK_INTERFACE\"\n",
                encoding="utf-8",
            )
            interface.chmod(0o755)

            scenarios = [
                ("4", True, True),
                ("absent", True, False),
                ("1", True, False),
                ("2", True, False),
                ("4", False, False),
            ]
            for index, (reported_interface, has_guide, accepted) in enumerate(scenarios):
                with self.subTest(interface=reported_interface, has_guide=has_guide):
                    if guide.exists():
                        guide.unlink()
                    if has_guide:
                        guide.parent.mkdir(parents=True, exist_ok=True)
                        guide.write_text("guide", encoding="utf-8")
                    github_env = root / f"github-env-{index}"
                    github_output = root / f"github-output-{index}"
                    environment = dict(
                        os.environ,
                        PATH=f"{binaries}:{os.environ['PATH']}",
                        GITHUB_ENV=str(github_env),
                        GITHUB_OUTPUT=str(github_output),
                        MOCK_INTERFACE=reported_interface,
                        MOCK_SOURCE_SHA="a" * 40,
                        NIGHTLY_RELEASE_INTERFACE_VERSION=required_interface,
                    )
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", script],
                        cwd=root, env=environment, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    if accepted:
                        self.assertEqual(github_env.read_text(), f"SOURCE_SHA={'a' * 40}\n")
                        self.assertEqual(github_output.read_text(), f"source_sha={'a' * 40}\n")
                    else:
                        self.assertIn("rollback refs must support release interface v4", result.stderr)

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
        release_step = workflow.split(
            "- name: Create immutable-by-workflow draft prerelease",
            1,
        )[1].split("\n      - name:", 1)[0]
        publication_step = workflow.split(
            "- name: Upload and publish verified Nightly assets",
            1,
        )[1].split("\n      - name:", 1)[0]
        metadata_publication_step = workflow.split(
            "- name: Publish dedicated Nightly catalog and appcast last",
            1,
        )[1].split("\n      - name:", 1)[0]

        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        self.assertIn("vars.ENABLE_NIGHTLY_RELEASES == 'true'", workflow)
        self.assertIn('git merge-base --is-ancestor "$SOURCE_SHA" origin/main', workflow)
        self.assertIn("refusing to expose release credentials", workflow)
        self.assertLess(
            workflow.index('git merge-base --is-ancestor "$SOURCE_SHA" origin/main'),
            workflow.index("release-interface-version"),
        )
        self.assertLess(
            workflow.index("release-interface-version"),
            workflow.index("Validate required secrets"),
        )
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
        self.assertIn('echo "release_id=$NIGHTLY_RELEASE_ID" >> "$GITHUB_OUTPUT"', release_step)
        self.assertIn('RELEASE_CATALOG_PATH="$RUNNER_TEMP/catalog.json"', publication_step)
        self.assertIn('cp "$SIGNED_PLUGIN_CATALOG_PATH" "$RELEASE_CATALOG_PATH"', publication_step)
        self.assertIn('"$RELEASE_CATALOG_PATH"', publication_step)
        self.assertNotIn('#catalog.json', publication_step)
        self.assertNotIn(
            'cp "$NIGHTLY_APPCAST_PATH" "$RUNNER_TEMP/nightly-appcast.xml"',
            metadata_publication_step,
        )
        self.assertIn(
            'cp "$NIGHTLY_APPCAST_PATH" "$NIGHTLY_APPCAST_RELATIVE_PATH"',
            metadata_publication_step,
        )
        self.assertIn("id: nightly_release", workflow)
        self.assertIn("Cleanup incomplete Nightly draft", workflow)
        self.assertIn("stale-draft-ids", workflow)
        self.assertIn('gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/$NIGHTLY_RELEASE_ID"', workflow)
        self.assertIn("preflight-app-plugin-catalog.swift", workflow)
        self.assertIn("Verify plugin catalog signing key", workflow)
        self.assertIn("verify-plugin-catalog-key-pair.sh", workflow)
        self.assertNotIn("pip install cryptography", workflow)
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

    def test_nightly_cli_guide_preserves_existing_cli_installations(self) -> None:
        guide = (REPO_ROOT / "docs/testing/cli-nightly-distribution.md").read_text(
            encoding="utf-8",
        )
        phase_zero_guide = (REPO_ROOT / "docs/testing/cli-phase-0.md").read_text(
            encoding="utf-8",
        )

        self.assertIn('$HOME/.local/bin/mactools-nightly', guide)
        self.assertIn('CLI_TEST_DIR="$(mktemp -d', guide)
        self.assertIn('ditto -x -k mactools-cli-1.2.1-123.1-macos-arm64.zip "$CLI_TEST_DIR"', guide)
        self.assertNotIn("ditto -x -k mactools-cli-1.2.1-123.1-macos-arm64.zip mactools-cli", guide)
        self.assertIn('[[ -e "$CLI_DEST" || -L "$CLI_DEST" ]]', guide)
        self.assertIn('if ! /usr/bin/python3 - "$CLI_SOURCE" "$CLI_DEST"', guide)
        self.assertIn('os.symlink(sys.argv[1], sys.argv[2])', guide)
        self.assertNotIn("ln -sf", guide)
        self.assertIn('[[ -L "$CLI_DEST" && "$(readlink "$CLI_DEST")" == "$CLI_SOURCE" ]]', guide)
        self.assertNotIn('$HOME/.local/bin/mactools"', guide)
        self.assertNotIn('rm "$HOME/.local/bin/mactools"', guide)
        self.assertIn('$HOME/.local/bin/mactools-dev', phase_zero_guide)
        self.assertIn('[[ -e "$CLI_DEST" || -L "$CLI_DEST" ]]', phase_zero_guide)
        self.assertIn('if ! /usr/bin/python3 - "$CLI_SOURCE" "$CLI_DEST"', phase_zero_guide)
        self.assertIn('os.symlink(sys.argv[1], sys.argv[2])', phase_zero_guide)
        self.assertNotIn("ln -sf", phase_zero_guide)
        self.assertNotIn('$HOME/.local/bin/mactools"', phase_zero_guide)

    def test_nightly_cli_guide_assesses_gatekeeper_on_the_app_bundle(self) -> None:
        guide = (REPO_ROOT / "docs/testing/cli-nightly-distribution.md").read_text(
            encoding="utf-8",
        )

        self.assertNotIn(
            'spctl --assess --type execute --verbose=2 "$CLI_PATH"',
            guide,
        )
        self.assertIn(
            'spctl --assess --type execute --verbose=2 "/Applications/MacTools Nightly.app"',
            guide,
        )
        self.assertIn("tickets cannot currently be stapled to standalone binaries", guide)

    def test_pages_deploy_waits_for_successful_nightly_workflow(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")

        self.assertIn('- "docs/nightly/**"', workflow)
        self.assertIn("- Nightly", workflow)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)


if __name__ == "__main__":
    unittest.main()
