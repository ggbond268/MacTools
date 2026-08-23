import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/validate-local-debug-config.sh"


class ValidateLocalDebugConfigTests(unittest.TestCase):
    def run_validation(self, contents: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            config = pathlib.Path(temporary_directory) / "LocalConfig.xcconfig"
            config.write_text(contents, encoding="utf-8")
            return subprocess.run(
                [str(SCRIPT), str(config), *arguments],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_prints_configured_debug_bundle_identifier(self) -> None:
        result = self.run_validation(
            "DEVELOPMENT_TEAM = ABC123\nBUNDLE_IDENTIFIER_PREFIX = org.exampledeveloper\n",
            "--print-bundle-identifier",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "org.exampledeveloper.mactools.dev")

    def test_rejects_placeholder_prefix(self) -> None:
        result = self.run_validation(
            "DEVELOPMENT_TEAM = ABC123\nBUNDLE_IDENTIFIER_PREFIX = com.example\n"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BUNDLE_IDENTIFIER_PREFIX must be configured", result.stderr)

    def test_rejects_empty_development_team(self) -> None:
        result = self.run_validation(
            "DEVELOPMENT_TEAM =\nBUNDLE_IDENTIFIER_PREFIX = org.exampledeveloper\n"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEVELOPMENT_TEAM must be configured", result.stderr)

    def test_rejects_malformed_prefix(self) -> None:
        result = self.run_validation(
            "DEVELOPMENT_TEAM = ABC123\nBUNDLE_IDENTIFIER_PREFIX = .mactools\n"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a valid reverse-DNS prefix", result.stderr)


if __name__ == "__main__":
    unittest.main()
