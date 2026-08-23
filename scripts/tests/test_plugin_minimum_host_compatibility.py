#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
LEGACY_V4_CATALOG = REPO_ROOT / "docs/plugins/v4/catalog.json"
PLUGIN_RELEASE_WORKFLOW = REPO_ROOT / ".github/workflows/plugin-release.yml"
MAKEFILE = REPO_ROOT / "Makefile"
ACTION_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/ActionModels.swift"
COMPONENT_THEME_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/PluginComponentTheme.swift"
NEW_API_MINIMUM_HOSTS = {
    # Canonical action registry, execution, discovery, and surface bridges.
    "ActionKey": "1.2.0",
    "ActionParameterSet": "1.2.0",
    "ActionParameterDefinition": "1.2.0",
    "ActionDefinition": "1.2.0",
    "ActionReference": "1.2.0",
    "ActionCatalogEntry": "1.2.0",
    "ActionAvailability": "1.2.0",
    "ActionRisk": "1.2.0",
    "ActionExecutionCapabilities": "1.2.0",
    "ActionConfirmation": "1.2.0",
    "ActionInvocation": "1.2.0",
    "ActionExecutionResult": "1.2.0",
    "ActionExecutionHandle": "1.2.0",
    "ActionExposureSurface": "1.2.0",
    "ActionExposurePolicy": "1.2.0",
    "PluginActionProviding": "1.2.0",
    "PluginActionShortcutSettingsConfiguration": "1.2.0",
    "PluginActionShortcutSettingsProviding": "1.2.0",
    "PluginActionExecutionRevisionProviding": "1.2.0",
    "PluginActionExposureProviding": "1.2.0",
    "PluginActionPermissionProviding": "1.2.0",
    "LegacyActionShortcutAssignment": "1.2.0",
    "PluginLegacyActionShortcutProviding": "1.2.0",
    "ActionSurfaceCatalogItem": "1.2.0",
    "ActionGridPresentationEntry": "1.2.0",
    "ActionGridHostContext": "1.2.0",
    "ActionGridHostContextConsuming": "1.2.0",
    "TrackpadActionHostContext": "1.2.0",
    "TrackpadActionHostContextConsuming": "1.2.0",
    "ActionSurfaceAssignmentSummary": "1.2.0",
    "ActionSurfaceAssignmentSummarizing": "1.2.0",
    # Portable preferences and input ownership added with the shared surfaces.
    "PluginPortablePreferencesRestorationReporting": "1.2.0",
    "PluginPortablePreferencesActionReferencesProviding": "1.2.0",
    "PluginActionReferenceBackupDisposition": "1.2.0",
    "PluginActionReferenceBackupProviding": "1.2.0",
    "PluginInputGestureClaim": "1.2.0",
    "PluginInputGestureConflict": "1.2.0",
    "PluginInputGestureClaimProviding": "1.2.0",
    "PluginInputGestureConflictConsuming": "1.2.0",
    # Shared lifecycle and presentation helpers introduced in host 1.2.
    "PluginCallbackContext": "1.2.0",
    "PluginPresentationSafety": "1.2.0",
    "PluginProcessGroupLease": "1.2.0",
    "PluginSystemImage": "1.2.0",
    # Shared component-panel theme surfaces introduced in host 1.2.
    "PluginComponentTheme": "1.2.0",
    "PluginComponentCardBackground": "1.2.0",
    "PluginActionSafetyStateChangeProviding": "1.2.0",
}


def source_uses_symbol(source: str, symbol: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])", source) is not None


def public_top_level_type_names(source: str) -> set[str]:
    return set(re.findall(
        r"^public\s+(?:final\s+)?(?:struct|enum|protocol|class|actor|typealias)\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)",
        source,
        flags=re.MULTILINE,
    ))


def minimum_host_violations(plugin_id: str, declared: str, source: str) -> list[str]:
    return [
        f"{plugin_id} uses {symbol} but declares "
        f"minHostVersion {declared} (< {required})"
        for symbol, required in NEW_API_MINIMUM_HOSTS.items()
        if source_uses_symbol(source, symbol)
        and version_tuple(declared) < version_tuple(required)
    ]


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(component) for component in value.split("."))


class PluginMinimumHostCompatibilityTests(unittest.TestCase):
    def test_legacy_v4_catalog_remains_compatible_with_shipped_1_1_6_verifier(self) -> None:
        catalog = json.loads(LEGACY_V4_CATALOG.read_text(encoding="utf-8"))
        self.assertEqual(catalog["minimumHostVersion"], "1.1.6")
        incompatible = [
            entry["id"]
            for entry in catalog["plugins"]
            if version_tuple(entry["minimumHostVersion"]) > version_tuple("1.1.6")
        ]
        self.assertEqual(incompatible, [])

    def test_plugin_kit5_release_targets_versioned_host_compatible_catalog(self) -> None:
        workflow = PLUGIN_RELEASE_WORKFLOW.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn(
            'PLUGIN_CATALOG_RELATIVE_PATH="docs/plugins/v5/catalog.json"',
            workflow,
        )
        self.assertIn('PLUGIN_CATALOG_MINIMUM_HOST_VERSION="1.2.0"', workflow)
        self.assertIn(
            "PLUGIN_CATALOG_MINIMUM_HOST_VERSION ?= $(if $(filter 5 6,$(PLUGIN_KIT_VERSION)),1.2.0,1.1.6)",
            makefile,
        )

    def test_every_current_plugin_targets_plugin_kit5_and_mac_tools_1_2(self) -> None:
        incompatible = []
        for manifest_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest["pluginKitVersion"] != 6 or manifest["minHostVersion"] != "1.2.0":
                incompatible.append(manifest["id"])
        self.assertEqual(incompatible, [])

    def test_new_plugin_kit_api_consumers_require_compatible_host(self) -> None:
        violations: list[str] = []
        for manifest_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            source = "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted((manifest_path.parent / "Sources").rglob("*.swift"))
            )
            declared = manifest.get("minHostVersion", "0")
            violations += minimum_host_violations(manifest["id"], declared, source)

        self.assertEqual(violations, [], "\n".join(violations))

    def test_action_model_inventory_covers_every_public_type_used_by_plugins(self) -> None:
        action_model_symbols = public_top_level_type_names(
            ACTION_MODELS.read_text(encoding="utf-8")
        )
        plugin_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(PLUGINS_ROOT.glob("*/Sources/**/*.swift"))
        )
        used_symbols = {
            symbol
            for symbol in action_model_symbols
            if source_uses_symbol(plugin_source, symbol)
        }
        self.assertEqual(
            used_symbols - NEW_API_MINIMUM_HOSTS.keys(),
            set(),
            "Public ActionModels types used by plugins must declare their minimum host",
        )

    def test_component_theme_inventory_covers_every_public_type_used_by_plugins(self) -> None:
        component_theme_symbols = public_top_level_type_names(
            COMPONENT_THEME_MODELS.read_text(encoding="utf-8")
        )
        plugin_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(PLUGINS_ROOT.glob("*/Sources/**/*.swift"))
        )
        used_symbols = {
            symbol
            for symbol in component_theme_symbols
            if source_uses_symbol(plugin_source, symbol)
        }
        self.assertEqual(
            used_symbols - NEW_API_MINIMUM_HOSTS.keys(),
            set(),
            "Public component-theme types used by plugins must declare their minimum host",
        )

    def test_symbol_matching_rejects_legacy_consumer_without_substring_false_positive(self) -> None:
        self.assertTrue(source_uses_symbol("let risk: ActionRisk = .safe", "ActionRisk"))
        self.assertFalse(source_uses_symbol("struct MyActionRiskWrapper {}", "ActionRisk"))
        self.assertEqual(
            minimum_host_violations(
                "synthetic-legacy-plugin",
                "1.1.6",
                "let risk: ActionRisk = .safe",
            ),
            [
                "synthetic-legacy-plugin uses ActionRisk but declares "
                "minHostVersion 1.1.6 (< 1.2.0)"
            ],
        )


if __name__ == "__main__":
    unittest.main()
