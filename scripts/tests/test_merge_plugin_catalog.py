#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/plugins/merge-plugin-catalog.py"


class MergePluginCatalogTests(unittest.TestCase):
    def test_merge_preserves_oldest_schema_host_floor_with_newer_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            previous = root / "previous.json"
            updates = root / "updates.json"
            plan = root / "plan.json"
            output = root / "merged.json"
            previous.write_text(json.dumps({
                "schemaVersion": 2,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.1.6",
                "pluginKitVersion": 4,
                "plugins": [{
                    "id": "legacy",
                    "version": "1.0.0",
                    "pluginKitVersion": 4,
                    "minimumHostVersion": "1.1.6",
                }],
            }), encoding="utf-8")
            updates.write_text(json.dumps({
                "schemaVersion": 2,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.2.0",
                "pluginKitVersion": 4,
                "plugins": [{
                    "id": "modern",
                    "version": "1.0.0",
                    "pluginKitVersion": 4,
                    "minimumHostVersion": "1.2.0",
                }],
            }), encoding="utf-8")
            plan.write_text(json.dumps({
                "selectedPluginIDs": ["modern"],
                "removedPluginIDs": [],
                "fullRelease": False,
            }), encoding="utf-8")

            subprocess.run([
                sys.executable,
                str(SCRIPT),
                "--previous", str(previous),
                "--updates", str(updates),
                "--plan", str(plan),
                "--output", str(output),
                "--plugin-kit-version", "4",
            ], check=True, capture_output=True, text=True)

            merged = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(merged["minimumHostVersion"], "1.1.6")
            self.assertEqual(
                [entry["id"] for entry in merged["plugins"]],
                ["legacy", "modern"],
            )

    def test_host_specific_catalog_can_raise_aggregate_host_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            previous = root / "previous.json"
            updates = root / "updates.json"
            plan = root / "plan.json"
            output = root / "merged.json"
            previous.write_text(json.dumps({
                "schemaVersion": 2,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.1.6",
                "pluginKitVersion": 4,
                "plugins": [],
            }), encoding="utf-8")
            updates.write_text(json.dumps({
                "schemaVersion": 2,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.2.0",
                "pluginKitVersion": 4,
                "plugins": [{
                    "id": "modern",
                    "version": "1.0.0",
                    "pluginKitVersion": 4,
                    "minimumHostVersion": "1.2.0",
                }],
            }), encoding="utf-8")
            plan.write_text(json.dumps({
                "selectedPluginIDs": ["modern"],
                "removedPluginIDs": [],
                "fullRelease": False,
            }), encoding="utf-8")

            subprocess.run([
                sys.executable,
                str(SCRIPT),
                "--previous", str(previous),
                "--updates", str(updates),
                "--plan", str(plan),
                "--output", str(output),
                "--plugin-kit-version", "4",
                "--minimum-host-version", "1.2.0",
            ], check=True, capture_output=True, text=True)

            merged = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(merged["minimumHostVersion"], "1.2.0")

    def test_schema3_merge_cannot_inherit_a_released_host_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            previous = root / "previous.json"
            updates = root / "updates.json"
            plan = root / "plan.json"
            output = root / "merged.json"
            previous.write_text(json.dumps({
                "schemaVersion": 2,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.2.0",
                "pluginKitVersion": 5,
                "plugins": [],
            }), encoding="utf-8")
            updates.write_text(json.dumps({
                "schemaVersion": 3,
                "catalogID": "test.catalog",
                "minimumHostVersion": "1.2.1",
                "pluginKitVersion": 5,
                "plugins": [{
                    "id": "modern",
                    "version": "1.0.0",
                    "pluginKitVersion": 5,
                    "minimumHostVersion": "1.2.0",
                }],
            }), encoding="utf-8")
            plan.write_text(json.dumps({
                "selectedPluginIDs": ["modern"],
                "removedPluginIDs": [],
                "fullRelease": False,
            }), encoding="utf-8")

            subprocess.run([
                sys.executable,
                str(SCRIPT),
                "--previous", str(previous),
                "--updates", str(updates),
                "--plan", str(plan),
                "--output", str(output),
                "--plugin-kit-version", "5",
            ], check=True, capture_output=True, text=True)

            merged = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(merged["schemaVersion"], 3)
            self.assertEqual(merged["minimumHostVersion"], "1.2.1")


if __name__ == "__main__":
    unittest.main()
