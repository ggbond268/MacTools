"""Guard the stable publication gate and the boundary around executable smoke tests."""
import json
import pathlib
import os
import tempfile
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class StableCLIReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ruby/Psych is already required by XcodeGen's plugin configuration generator.
        cls.workflow = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
            str(ROOT / ".github/workflows/release.yml"),
        ], text=True))

    def test_cli_publication_defaults_off_and_release_requires_verification(self):
        self.assertEqual(self.workflow["env"]["STABLE_CLI_ENABLED"], "false")
        publish = self.workflow["jobs"]["publish"]
        self.assertEqual(publish["needs"], ["release", "verify_cli"])
        self.assertNotIn("cli_candidate", json.dumps(self.workflow))
        build = self.workflow["jobs"]["release"]
        runs = "\n".join(step.get("run", "") for step in build["steps"])
        self.assertNotIn("gh release create", runs)
        self.assertNotIn("git push", runs)
        self.assertNotIn("STABLE_CLI_ENABLED=true", runs)
        checkout = next(s for s in build["steps"] if s["name"] == "Checkout")
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.inputs.tag || github.ref }}")

    def test_signing_and_execution_use_separate_jobs_and_same_artifact(self):
        build = self.workflow["jobs"]["release"]
        verify = self.workflow["jobs"]["verify_cli"]
        self.assertEqual(verify["permissions"], {"contents": "read"})
        self.assertFalse(verify["steps"][0]["with"]["persist-credentials"])
        self.assertNotIn("secrets.", json.dumps(verify))
        for job in (verify, self.workflow["jobs"]["publish"]):
            downloads = [s for s in job["steps"] if s.get("uses", "").startswith("actions/download-artifact@")]
            self.assertEqual(len(downloads), 1)
            self.assertEqual(downloads[0]["with"]["artifact-ids"], "${{ needs.release.outputs.artifact_id }}")
        runs = "\n".join(s.get("run", "") for s in build["steps"])
        self.assertIn("verify-cli-archive --channel stable --skip-execution", runs)
        names = [s["name"] for s in build["steps"]]
        self.assertLess(names.index("Package optional stable CLI and seal installation metadata"), names.index("Sign app bundle"))
        self.assertLess(names.index("Statically verify notarized stable CLI"), names.index("Upload immutable release candidate"))
        package = next(s for s in build["steps"] if s["name"].startswith("Package optional"))
        self.assertEqual(package["if"], "env.STABLE_CLI_ENABLED == 'true'")
        self.assertLess(package["run"].index("/usr/bin/codesign"), package["run"].index("package-cli"))
        self.assertLess(package["run"].index("package-cli"), package["run"].index("cli-install-manifest.py"))

    def test_localized_install_copy_is_channel_neutral(self):
        strings = json.loads((ROOT / "Sources/Resources/Localization/Settings.xcstrings").read_text())["strings"]
        keys = ["cli.install.confirmTitle"] + ["cli.install.error." + kind for kind in
            ("unsupported", "metadata", "signature", "notarization", "identity", "collision")]
        for key in keys:
            self.assertEqual(len(strings[key]["localizations"]), 11)
            for language, entry in strings[key]["localizations"].items():
                text = entry["stringUnit"]["value"]
                with self.subTest(key=key, language=language):
                    self.assertNotIn("Nightly", text)
                    self.assertNotIn("mactools-nightly", text)
                    self.assertEqual(entry["stringUnit"]["state"], "translated")

    def test_publisher_preserves_existing_cli_releases_and_uploads_matching_assets(self):
        script = next(step["run"] for step in self.workflow["jobs"]["publish"]["steps"]
                      if step["name"] == "Create or update GitHub Release")
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            # A local shell function replaces gh; no network request or release mutation occurs.
            stub = """gh() {
              printf '%s\\n' "$*" >> "$CALLS"
              if [[ "$1 $2" == "release view" ]]; then
                [[ "$EXISTING" == "true" ]]
              else
                return 0
              fi
            }
            """
            for enabled, existing in [("false", "false"), ("false", "true"), ("true", "false"), ("true", "true")]:
                calls = root / "calls"
                calls.write_text("")
                env = dict(os.environ, CLI_ENABLED=enabled, EXISTING=existing, CALLS=str(calls),
                           PROJECT_NAME="MacTools", VERSION="1.3.0", BUILD_NUMBER="123",
                           TAG="v1.3.0", PRERELEASE="false", DMG_PATH="candidate/MacTools.dmg",
                           SHA256_PATH="candidate/MacTools.sha256", RELEASE_NOTES_PATH="candidate/release-notes.md")
                result = subprocess.run(["bash", "-e", "-u", "-o", "pipefail", "-c", stub + script],
                                        env=env, capture_output=True, text=True)
                commands = calls.read_text()
                with self.subTest(enabled=enabled, existing=existing):
                    if enabled == existing == "true":
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn("release upload", commands)
                        self.assertNotIn("release create", commands)
                        self.assertNotIn("release edit", commands)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("candidate/MacTools.dmg#MacTools.dmg", commands)
                        if enabled == "true":
                            self.assertIn("candidate/mactools-cli-1.3.0-123-macos-arm64.zip", commands)
                            self.assertIn("candidate/cli-install.json", commands)
                            self.assertNotIn("--clobber", commands)
                        else:
                            self.assertNotIn("cli-install.json", commands)
