import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cli_install_manifest", ROOT / "scripts/cli-install-manifest.py")
manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manifest)


class CLIInstallManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "Nightly.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = dict(CFBundleIdentifier="test.mactools.nightly", MTReleaseChannel="nightly",
                         CFBundleShortVersionString="1.3.0", CFBundleVersion="123.1")
        self.write_info()
        self.archive = self.root / "mactools-cli-1.3.0-123.1-macos-arm64.zip"
        self.write_zip()
        self.protocol = ROOT / "Sources/MacToolsCLIProtocol/CLIProtocolModels.swift"

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def write_zip(self, extra=None, mode=0o100755, architecture=bytes.fromhex("cffaedfe0c000001")):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, data, permissions in [("mactools", architecture + b"fixture", mode),
                                             ("LICENSE", b"license", 0o100644)]:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = permissions << 16
                archive.writestr(info, data)
            if extra:
                archive.writestr(extra, "unexpected")

    def make(self, url="https://example.invalid/releases/123.1"):
        return manifest.make_manifest(self.archive, self.app, url, "a" * 40, "TESTTEAM00", self.protocol)

    def test_official_and_local_immutable_channels(self):
        for url in ["https://example.invalid/releases/123.1",
                    "https://github.com/owner/repository/releases/download/nightly-123-1"]:
            result = self.make(url)
            self.assertEqual(result["assetURL"], url + "/" + self.archive.name)
            self.assertEqual(result["cliBuild"], result["appBuild"])
            self.assertEqual(result["size"], self.archive.stat().st_size)
            self.assertEqual(len(result["sha256"]), 64)

    def test_rejects_mutable_or_credential_bearing_urls(self):
        for url in ["http://example.invalid/releases/123.1", "https://example.invalid/current",
                    "https://user:secret@example.invalid/releases/123.1", "https://example.invalid/releases/123.1?secret=1",
                    "https://example.invalid/releases/124.1", "https://example.invalid/releases/%31%32%33.1"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.make(url)

    def test_stable_app_is_rejected(self):
        self.info["MTReleaseChannel"] = "stable"
        self.write_info()
        with self.assertRaises(ValueError):
            self.make()

    def test_rejects_traversal_symlinks_and_wrong_architecture(self):
        for options in [dict(extra="../bad"), dict(mode=0o120755), dict(architecture=b"x86_64")]:
            self.write_zip(**options)
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.make()

    def test_cli_embeds_identical_metadata_before_app_signing(self):
        output = self.root / "release/cli-install.json"
        subprocess.run([sys.executable, str(ROOT / "scripts/cli-install-manifest.py"),
                        "--archive", str(self.archive), "--app", str(self.app),
                        "--source-release", "https://example.invalid/releases/123.1",
                        "--source-commit", "a" * 40, "--team", "TESTTEAM00", "--output", str(output)], check=True)
        self.assertEqual(output.read_bytes(), (self.app / "Contents/Resources/cli-install.json").read_bytes())
        self.assertEqual(json.loads(output.read_text()), self.make())

    def test_workflow_seals_manifest_and_publishes_exact_archive(self):
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        signing = workflow.split("- name: Sign app bundle", 1)[1].split("\n      - name:", 1)[0]
        self.assertLess(signing.index('sign_path "$CLI_PATH"'), signing.index("package-cli"))
        self.assertLess(signing.index("package-cli"), signing.index("cli-install-manifest.py"))
        self.assertLess(signing.index("cli-install-manifest.py"), signing.index('--entitlements "$ENTITLEMENTS"'))
        self.assertEqual(workflow.count("scripts/nightly-release.py package-cli"), 1)
        self.assertIn('"$ARTIFACT_ROOT/cli-install.json"', workflow.split("Upload and publish verified Nightly assets", 1)[1])
