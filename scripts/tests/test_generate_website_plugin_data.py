from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "plugins"))

from generate_website_plugin_data import (  # noqa: E402
    canonical_json,
    generate,
    mac_tools_url,
    project_manifests,
)


class GenerateWebsitePluginDataTests(unittest.TestCase):
    def test_projection_is_deterministic_and_contains_only_static_action_pages(self) -> None:
        first = project_manifests(REPO_ROOT / "Plugins")
        second = project_manifests(REPO_ROOT / "Plugins")

        self.assertEqual(canonical_json(first), canonical_json(second))
        actions = first["actions"]
        self.assertTrue(actions)
        self.assertTrue(all("dynamicTemplates" not in action for action in actions))
        self.assertEqual(
            hashlib.sha256(canonical_json(first)).hexdigest(),
            hashlib.sha256(canonical_json(second)).hexdigest(),
        )

    def test_action_search_and_open_in_mactools_links_preserve_provider_identity(self) -> None:
        projection = project_manifests(REPO_ROOT / "Plugins")
        action = next(
            item for item in projection["actions"]
            if item["pluginID"] == "appearance" and item["action"]["id"] == "toggle"
        )

        self.assertEqual(
            action["openInMacToolsURL"],
            "mactools://app/settings/plugins/marketplace/appearance?provider=appearance&action=toggle",
        )
        self.assertIn(action["route"], {route["path"] for route in projection["routes"]})
        self.assertTrue(any(
            entry.get("actionID") == "toggle" and entry.get("providerID") == "appearance"
            for entry in projection["search"]
        ))
        self.assertEqual(
            mac_tools_url("appearance"),
            "mactools://app/settings/plugins/marketplace/appearance",
        )
        with self.assertRaises(ValueError):
            mac_tools_url("appearance", provider_id="appearance")
        with self.assertRaises(ValueError):
            mac_tools_url("appearance", action_id="toggle")

    def test_plugin_search_projection_contains_every_supported_locale(self) -> None:
        projection = project_manifests(REPO_ROOT / "Plugins")
        entry = next(item for item in projection["search"] if item["kind"] == "plugin")
        self.assertIn("localized", entry)
        self.assertIn("en", entry["localized"])
        self.assertIn("zh-Hans", entry["localized"])
        self.assertTrue(entry["localized"]["en"]["title"])

    def test_generator_check_detects_stale_or_missing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            output = root / "generated"
            assets = root / "assets"

            self.assertTrue(generate(REPO_ROOT, output, assets, check=False))
            self.assertTrue(generate(REPO_ROOT, output, assets, check=True))

            plugins_path = output / "plugins.json"
            plugins = json.loads(plugins_path.read_text(encoding="utf-8"))
            plugins["generatorVersion"] = 0
            plugins_path.write_text(json.dumps(plugins), encoding="utf-8")

            self.assertFalse(generate(REPO_ROOT, output, assets, check=True))

    def test_generator_check_detects_and_generation_removes_orphaned_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            output = root / "generated"
            assets = root / "assets"

            self.assertTrue(generate(REPO_ROOT, output, assets, check=False))
            assets.mkdir(parents=True, exist_ok=True)
            orphan = assets / "orphan.png"
            orphan.write_bytes(b"obsolete")

            self.assertFalse(generate(REPO_ROOT, output, assets, check=True))
            self.assertTrue(orphan.exists())
            self.assertTrue(generate(REPO_ROOT, output, assets, check=False))
            self.assertFalse(orphan.exists())
