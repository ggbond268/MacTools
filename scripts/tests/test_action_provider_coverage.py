import json
import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
COVERAGE_DOCUMENT = REPO_ROOT / "docs" / "plugins" / "action-provider-coverage.md"
PLUGINS_ROOT = REPO_ROOT / "Plugins"
E2E_SCRIPT = REPO_ROOT / "scripts" / "e2e" / "mactools-e2e.sh"
RUNTIME_METADATA_TEST = (
    REPO_ROOT / "Tests/Core/Plugins/Dynamic/PluginRuntimeActionSnapshotTests.swift"
)


class ActionProviderCoverageTests(unittest.TestCase):
    def test_every_plugin_directory_is_a_provider_or_an_explicit_exclusion(self):
        document = COVERAGE_DOCUMENT.read_text(encoding="utf-8")
        providers = self.directory_names(
            document,
            "## Migrated providers",
            "Parameterized actions publish",
        )
        exclusions = self.directory_names(
            document,
            "## Intentionally specialized or non-operational",
            "Specialized shortcuts may remain",
        )
        manifest_directories = {
            path.parent.name for path in PLUGINS_ROOT.glob("*/plugin.json")
        }

        self.assertFalse(providers & exclusions)
        self.assertEqual(providers | exclusions, manifest_directories)

    def test_every_documented_provider_is_in_the_e2e_registry_checkpoint(self):
        document = COVERAGE_DOCUMENT.read_text(encoding="utf-8")
        providers = self.directory_names(
            document,
            "## Migrated providers",
            "Parameterized actions publish",
        )
        suite_overrides = {
            "AutoInput": "AutoInputPluginPanelTests",
            "KeepAwake": "KeepAwakePreferenceTests",
            "LaunchControl": "LaunchControlCanonicalActionTests",
            "Launchpad": "LaunchpadPluginActionTests",
        }
        harness = E2E_SCRIPT.read_text(encoding="utf-8")

        missing = []
        for provider in sorted(providers):
            suite = suite_overrides.get(provider, f"{provider}PluginTests")
            selector = f"-only-testing:MacToolsTests/{suite}"
            if selector not in harness:
                missing.append((provider, suite))

        self.assertEqual(missing, [])

    def test_every_documented_provider_is_in_the_manifest_runtime_consistency_test(self):
        document = COVERAGE_DOCUMENT.read_text(encoding="utf-8")
        providers = self.directory_names(
            document,
            "## Migrated providers",
            "Parameterized actions publish",
        )
        harness = RUNTIME_METADATA_TEST.read_text(encoding="utf-8")
        missing = []
        for directory in sorted(providers):
            manifest = json.loads(
                (PLUGINS_ROOT / directory / "plugin.json").read_text(encoding="utf-8")
            )
            if f'pluginID: "{manifest["id"]}"' not in harness:
                missing.append(directory)

        self.assertEqual(missing, [])

    @staticmethod
    def directory_names(document: str, start: str, end: str):
        section = document.split(start, 1)[1].split(end, 1)[0]
        return set(re.findall(r"`([A-Za-z][A-Za-z0-9]+)`", section))


if __name__ == "__main__":
    unittest.main()
