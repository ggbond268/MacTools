from __future__ import annotations

import base64
import copy
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
SCRIPTS_ROOT = REPO_ROOT / "scripts" / "plugins"
sys.path.insert(0, str(SCRIPTS_ROOT))

from plugin_source_manifest import (  # noqa: E402
    ManifestValidationError,
    SUPPORTED_LOCALES,
    load_known_plugin_ids,
    validate_and_project_manifest,
)


class PluginSourceManifestTests(unittest.TestCase):
    def test_every_repository_manifest_passes_semantic_validation(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            with self.subTest(plugin=path.parent.name):
                validate_and_project_manifest(
                    json.loads(path.read_text(encoding="utf-8")),
                    path,
                    known_ids,
                )

    def test_all_repository_manifests_publish_complete_product_metadata(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        required_sections = {
            "presentation", "discovery", "requirements", "privacy", "setup", "relationships"
        }
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            with self.subTest(plugin=manifest["id"]):
                self.assertTrue(required_sections.issubset(manifest))
                self.assertEqual(set(manifest["localizedMetadata"]), SUPPORTED_LOCALES)
                projected, _ = validate_and_project_manifest(manifest, path, known_ids)
                self.assertEqual(
                    set(projected["presentation"]["longDescription"]),
                    SUPPORTED_LOCALES,
                )

    def test_source_localization_references_expand_before_projection(self) -> None:
        path = PLUGINS_ROOT / "ActivityBar" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(
            manifest["presentation"]["longDescription"],
            "@productStrings.summary",
        )
        self.assertEqual(manifest["productStrings"]["summary"], "@summary")
        projected, _ = validate_and_project_manifest(
            manifest,
            path,
            load_known_plugin_ids(PLUGINS_ROOT),
        )

        self.assertEqual(
            projected["presentation"]["longDescription"]["en"],
            manifest["localizedMetadata"]["en"]["summary"],
        )
        self.assertNotIn("productStrings", projected)

    def test_standard_setup_references_expand_declared_requirements(self) -> None:
        path = PLUGINS_ROOT / "Calendar" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        projected, _ = validate_and_project_manifest(
            manifest,
            path,
            load_known_plugin_ids(PLUGINS_ROOT),
        )

        step = projected["setup"]["steps"][0]
        self.assertEqual(step["title"]["en"], "Set Up Calendar")
        self.assertIn("Full Calendar Access", step["description"]["en"])
        self.assertIn("Automation permission", step["description"]["en"])

    def test_repository_product_text_uses_only_declared_product_string_references(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            with self.subTest(plugin=manifest["id"]):
                self.assertTrue(manifest["productStrings"])
                projected, _ = validate_and_project_manifest(manifest, path, known_ids)
                self.assertNotIn("productStrings", projected)

    def test_inline_missing_and_unused_product_strings_are_rejected(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        inline = copy.deepcopy(manifest)
        inline["presentation"]["longDescription"] = inline["productStrings"]["long-description"]
        with self.assertRaisesRegex(ManifestValidationError, "inline localized text is not allowed"):
            validate_and_project_manifest(inline, path, known_ids)

        missing = copy.deepcopy(manifest)
        missing["presentation"]["longDescription"] = "@productStrings.missing"
        with self.assertRaisesRegex(ManifestValidationError, "references missing productStrings entry"):
            validate_and_project_manifest(missing, path, known_ids)

        unused = copy.deepcopy(manifest)
        unused["productStrings"]["unused"] = "@summary"
        with self.assertRaisesRegex(ManifestValidationError, "contains unused entries: unused"):
            validate_and_project_manifest(unused, path, known_ids)

    def test_reviewed_runtime_requirements_and_disclosures_stay_accurate(self) -> None:
        expected_permissions = {
            "ActivityBar": ["inputMonitoring"],
            "AppVolume": ["system-audio-recording"],
            "Appearance": ["automation"],
            "AppleShortcuts": ["automation"],
            "AutoHideDock": ["automation"],
            "AutoHideMenuBar": ["automation"],
            "EmptyTrash": ["automation"],
            "RightClick": [],
            "DeviceBattery": ["inputMonitoring"],
            "ZshConfig": ["automation"],
        }
        for directory, permissions in expected_permissions.items():
            manifest = json.loads(
                (PLUGINS_ROOT / directory / "plugin.json").read_text(encoding="utf-8")
            )
            with self.subTest(plugin=manifest["id"]):
                self.assertEqual(manifest["permissions"], permissions)
                self.assertEqual(manifest["requirements"]["permissionIDs"], permissions)

        battery = json.loads(
            (PLUGINS_ROOT / "BatteryChargeLimit" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(set(battery["requirements"]["architectures"]), {"arm64", "x86_64"})
        self.assertNotIn("Apple Silicon Mac", battery["requirements"]["hardware"])

        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        privileged_helpers = {
            "BatteryChargeLimit": (
                "cc.ggbond.mactools.battery-charge-limit.smc-helper",
                "built-in battery",
            ),
            "FanControl": (
                "cc.ggbond.mactools.fan-control.smc-helper",
                "system fans",
            ),
        }
        for directory, (helper_name, hardware_copy) in privileged_helpers.items():
            path = PLUGINS_ROOT / directory / "plugin.json"
            manifest = json.loads(path.read_text(encoding="utf-8"))
            projected, _ = validate_and_project_manifest(manifest, path, known_ids)
            steps = {step["id"]: step for step in projected["setup"]["steps"]}
            with self.subTest(plugin=manifest["id"], disclosure="privileged-helper"):
                self.assertEqual(
                    set(steps),
                    {"install-privileged-helper", "verify-compatible-hardware"},
                )
                helper_description = steps["install-privileged-helper"]["description"]["en"]
                self.assertIn("administrator authorization", helper_description)
                self.assertIn("root-owned, mode-4755 helper", helper_description)
                self.assertIn(
                    f"/Library/PrivilegedHelperTools/{helper_name}",
                    helper_description,
                )
                self.assertIn(
                    hardware_copy,
                    steps["verify-compatible-hardware"]["description"]["en"],
                )

        zsh_path = PLUGINS_ROOT / "ZshConfig" / "plugin.json"
        zsh_manifest = json.loads(zsh_path.read_text(encoding="utf-8"))
        zsh_projected, _ = validate_and_project_manifest(zsh_manifest, zsh_path, known_ids)
        zsh_retention = zsh_projected["privacy"]["retention"]["description"]["en"]
        self.assertIn("one .bak backup per edited shell file", zsh_retention)
        self.assertIn("next save of that file replaces its backup", zsh_retention)
        self.assertIn("until you remove them", zsh_retention)

        cloudflare = json.loads(
            (PLUGINS_ROOT / "CloudflareR2" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(cloudflare["requirements"]["setupComplexity"], "advanced")
        self.assertTrue(cloudflare["setup"]["steps"])

        right_click = json.loads(
            (PLUGINS_ROOT / "RightClick" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(right_click["permissions"], [])
        self.assertEqual(right_click["requirements"]["permissionIDs"], [])
        self.assertEqual(right_click["requirements"]["setupComplexity"], "guided")
        self.assertTrue(right_click["setup"]["steps"])

        translator = json.loads(
            (PLUGINS_ROOT / "Translator" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(translator["privacy"]["networkDomains"], ["api.openai.com"])
        translator_actions = {
            action["id"]: action["permissionIDs"]
            for action in translator["actions"]["providers"][0]["staticActions"]
        }
        self.assertEqual(
            translator_actions,
            {
                "select-translation": ["accessibility", "automation"],
                "screenshot-translation": ["screen-recording"],
            },
        )

        auto_input = json.loads(
            (PLUGINS_ROOT / "AutoInput" / "plugin.json").read_text(encoding="utf-8")
        )
        auto_input_actions = auto_input["actions"]["providers"][0]
        self.assertTrue(
            all(
                not action["permissionIDs"]
                for action in (
                    auto_input_actions["staticActions"]
                    + auto_input_actions["dynamicTemplates"]
                )
            )
        )

        activity = json.loads(
            (PLUGINS_ROOT / "ActivityBar" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertTrue(activity["privacy"]["processesSensitiveUserContent"])
        self.assertTrue(
            {"ai-prompt-content", "project-working-directories"}.issubset(
                activity["privacy"]["dataObserved"]
            )
        )
        self.assertTrue(
            {"usage-statistics", "coding-session-statistics"}.issubset(
                activity["privacy"]["dataPersisted"]
            )
        )

        shortcuts = json.loads(
            (PLUGINS_ROOT / "AppleShortcuts" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertTrue(shortcuts["privacy"]["processesSensitiveUserContent"])
        shortcut_template = shortcuts["actions"]["providers"][0]["dynamicTemplates"][0]
        self.assertTrue(shortcut_template["riskVariesByEntry"])
        self.assertNotIn("automaticEligibilityVariesByEntry", shortcut_template)
        self.assertEqual(shortcut_template["risk"], "confirmationRequired")
        self.assertEqual(shortcut_template["externalInvocation"], "confirmAlways")
        self.assertIn("run-link", shortcut_template["surfaces"])

        scripts = json.loads(
            (PLUGINS_ROOT / "SavedScripts" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertTrue(
            {"script-content", "script-working-directories"}.issubset(
                scripts["privacy"]["dataPersisted"]
            )
        )
        self.assertIn("script-working-directories", scripts["privacy"]["dataObserved"])
        script_template = scripts["actions"]["providers"][0]["dynamicTemplates"][0]
        self.assertTrue(script_template["riskVariesByEntry"])
        self.assertTrue(script_template["automaticEligibilityVariesByEntry"])
        self.assertEqual(script_template["risk"], "confirmationRequired")
        self.assertEqual(script_template["externalInvocation"], "configurable")
        self.assertTrue(
            {"run-link", "automatic-rule"}.issubset(script_template["surfaces"])
        )

        layouts = json.loads(
            (PLUGINS_ROOT / "WindowLayouts" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertTrue(layouts["privacy"]["processesSensitiveUserContent"])
        custom = layouts["actions"]["providers"][0]["dynamicTemplates"][0]
        self.assertEqual(custom["externalInvocation"], "configurable")
        self.assertIn("run-link", custom["surfaces"])

    def test_automation_permission_runtime_copy_is_fully_localized(self) -> None:
        expected_keys = {
            "permission.automation.title",
            "permission.automation.description",
            "permission.automation.footnote",
            "permission.automation.status",
        }
        expected_locales = {
            "Appearance": SUPPORTED_LOCALES,
            "AppleShortcuts": SUPPORTED_LOCALES,
            "AutoHideDock": SUPPORTED_LOCALES,
            "AutoHideMenuBar": SUPPORTED_LOCALES,
            "ZshConfig": SUPPORTED_LOCALES,
        }

        for directory, locales in expected_locales.items():
            source = "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted((PLUGINS_ROOT / directory / "Sources").glob("*.swift"))
            )
            source_keys = set(
                re.findall(r'localization\.string\(\s*"(permission\.automation\.[^"]+)"', source)
            )
            catalog = json.loads(
                (PLUGINS_ROOT / directory / "Resources" / "Localizable.xcstrings").read_text(
                    encoding="utf-8"
                )
            )["strings"]

            with self.subTest(plugin=directory):
                self.assertEqual(source_keys, expected_keys)
                for key in expected_keys:
                    self.assertIn(key, catalog)
                    self.assertEqual(set(catalog[key]["localizations"]), locales)

    def test_action_permissions_must_be_declared_by_plugin_and_requirements(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        missing_top_level = copy.deepcopy(manifest)
        missing_top_level["permissions"] = []
        with self.assertRaisesRegex(ManifestValidationError, "top-level permissions"):
            validate_and_project_manifest(missing_top_level, path, known_ids)

        missing_requirements = copy.deepcopy(manifest)
        missing_requirements["requirements"]["permissionIDs"] = []
        with self.assertRaisesRegex(ManifestValidationError, "requirements.permissionIDs"):
            validate_and_project_manifest(missing_requirements, path, known_ids)

    def test_optional_urls_reject_explicit_null(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        for key in ("documentationURL", "supportURL"):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["presentation"][key] = None
            with self.subTest(field=key), self.assertRaisesRegex(
                ManifestValidationError,
                "must be an HTTPS URL",
            ):
                validate_and_project_manifest(manifest, path, known_ids)

    def test_presentation_example_ids_match_json_schema(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["presentation"]["examples"][0]["id"] = "bad/example"

        with self.assertRaisesRegex(ManifestValidationError, "stable identifier"):
            validate_and_project_manifest(
                manifest,
                path,
                load_known_plugin_ids(PLUGINS_ROOT),
            )

    def test_versions_match_json_schema_shape(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        schema = json.loads(
            (REPO_ROOT / "docs" / "plugins" / "plugin-manifest.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(schema["$defs"]["version"]["pattern"], r"^[0-9]+(?:\.[0-9]+){0,2}$")

        for field, value in (
            ("version", "1.2.3.4"),
            ("minHostVersion", "v1.2"),
        ):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                ManifestValidationError,
                "numeric version components",
            ):
                validate_and_project_manifest(manifest, path, known_ids)

        for value in (None, "14.0.0.1", "macOS 14"):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["requirements"]["minimumMacOSVersion"] = value
            with self.subTest(minimum=value), self.assertRaisesRegex(
                ManifestValidationError,
                "numeric version components",
            ):
                validate_and_project_manifest(manifest, path, known_ids)

    def test_runtime_envelope_schema_matches_source_validator(self) -> None:
        schema = json.loads(
            (REPO_ROOT / "docs" / "plugins" / "plugin-manifest.schema.json").read_text(
                encoding="utf-8"
            )
        )
        definitions = schema["$defs"]
        self.assertEqual(schema["properties"]["id"]["$ref"], "#/$defs/pluginIdentifier")
        self.assertEqual(
            definitions["pluginIdentifier"]["pattern"],
            r"^[A-Za-z0-9][A-Za-z0-9._-]{1,126}[A-Za-z0-9]$",
        )
        self.assertEqual(definitions["pluginIdentifier"]["not"], {"const": "marketplace"})
        self.assertEqual(
            schema["properties"]["bundleRelativePath"]["$ref"],
            "#/$defs/bundleRelativePath",
        )
        self.assertEqual(
            schema["properties"]["localizedMetadata"]["$ref"],
            "#/$defs/localizedMetadata",
        )
        self.assertEqual(schema["properties"]["releaseChannel"]["type"], "string")
        self.assertEqual(schema["properties"]["releaseNotesURL"]["pattern"], "^https://")
        capabilities = definitions["capabilities"]
        self.assertEqual(
            set(capabilities["required"]),
            {"primaryPanel", "componentPanel", "settings"},
        )
        self.assertFalse(capabilities["additionalProperties"])
        self.assertEqual(
            set(capabilities["properties"]["settings"]["enum"]),
            {"none", "form", "workspace"},
        )

    def test_sparse_legacy_runtime_envelopes_remain_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = pathlib.Path(temporary_directory) / "plugin.json"
            fixtures = (
                (3, {"primaryPanel": True, "configuration": True}),
                (4, {"componentPanel": True, "settings": "form"}),
            )
            for plugin_kit_version, capabilities in fixtures:
                manifest = {
                    "id": "legacy-demo",
                    "displayName": "Legacy",
                    "version": "1.0.0",
                    "minHostVersion": "1.0.0",
                    "pluginKitVersion": plugin_kit_version,
                    "bundleRelativePath": "Legacy.bundle",
                    "capabilities": capabilities,
                    "permissions": [],
                }
                path.write_text(json.dumps(manifest), encoding="utf-8")

                with self.subTest(pluginKitVersion=plugin_kit_version):
                    projected, assets = validate_and_project_manifest(
                        manifest,
                        path,
                        {"legacy-demo"},
                        allow_sparse_legacy=True,
                    )

                    self.assertNotIn("presentation", projected)
                    self.assertEqual(assets, [])

    def test_runtime_envelope_mutations_are_rejected(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        mutations = {
            "reserved id": lambda value: value.__setitem__("id", "marketplace"),
            "empty display name": lambda value: value.__setitem__("displayName", ""),
            "string PluginKit version": lambda value: value.__setitem__("pluginKitVersion", "5"),
            "traversal bundle path": lambda value: value.__setitem__(
                "bundleRelativePath", "../Bad.bundle"
            ),
            "array capabilities": lambda value: value.__setitem__("capabilities", []),
            "incomplete capabilities": lambda value: value.__setitem__(
                "capabilities", {"primaryPanel": True}
            ),
            "numeric summary": lambda value: value.__setitem__("summary", 4),
            "empty summary": lambda value: value.__setitem__("summary", ""),
            "array localized metadata": lambda value: value.__setitem__(
                "localizedMetadata", []
            ),
            "invalid localized metadata entry": lambda value: value.__setitem__(
                "localizedMetadata", {"en": 4}
            ),
            "numeric release channel": lambda value: value.__setitem__("releaseChannel", 4),
            "empty release channel": lambda value: value.__setitem__("releaseChannel", ""),
            "numeric release notes URL": lambda value: value.__setitem__("releaseNotesURL", 4),
            "invalid release notes URL": lambda value: value.__setitem__(
                "releaseNotesURL", "not-a-url"
            ),
            "release notes URL with host whitespace": lambda value: value.__setitem__(
                "releaseNotesURL", "https://bad host/path"
            ),
            "release notes URL with invalid port": lambda value: value.__setitem__(
                "releaseNotesURL", "https://example.com:abc/x"
            ),
        }
        for name, mutate in mutations.items():
            invalid = copy.deepcopy(manifest)
            mutate(invalid)
            with self.subTest(mutation=name), self.assertRaises(ManifestValidationError):
                validate_and_project_manifest(invalid, path, known_ids)

    def test_catalog_rejects_invalid_packaged_runtime_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = root / "appearance.mactoolsplugin"
            package.mkdir()
            packaged_manifest = json.loads(
                (PLUGINS_ROOT / "Appearance" / "plugin.json").read_text(encoding="utf-8")
            )
            packaged_manifest["capabilities"] = []
            package.joinpath("plugin.json").write_text(
                json.dumps(packaged_manifest),
                encoding="utf-8",
            )
            package.joinpath("Appearance.bundle").mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_ROOT / "generate-plugin-catalog.py"),
                    "--mode", "debug",
                    "--output", str(root / "catalog.json"),
                    "--package", str(package),
                    "--plugins-root", str(PLUGINS_ROOT),
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("capabilities", result.stderr)

    def test_duplicate_plugin_ids_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            for name in ("First", "Second"):
                directory = root / name
                directory.mkdir()
                directory.joinpath("plugin.json").write_text(
                    json.dumps({"id": "duplicate"}),
                    encoding="utf-8",
                )

            with self.assertRaisesRegex(ManifestValidationError, "duplicates another plugin"):
                load_known_plugin_ids(root)

    def test_rejects_missing_localization_invalid_domain_and_duplicate_action(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        missing_locale = copy.deepcopy(manifest)
        missing_locale["productStrings"]["long-description"].pop("fr")
        with self.assertRaisesRegex(ManifestValidationError, "missing locale fallback"):
            validate_and_project_manifest(missing_locale, path, known_ids)

        invalid_domain = copy.deepcopy(manifest)
        invalid_domain["privacy"]["networkUse"] = "required"
        invalid_domain["privacy"]["networkDomains"] = ["https://example.com/path"]
        with self.assertRaisesRegex(ManifestValidationError, "invalid domain"):
            validate_and_project_manifest(invalid_domain, path, known_ids)

        duplicate_action = copy.deepcopy(manifest)
        duplicate_action["actions"]["providers"][0]["staticActions"].append(
            copy.deepcopy(duplicate_action["actions"]["providers"][0]["staticActions"][0])
        )
        with self.assertRaisesRegex(ManifestValidationError, "duplicates a static action key"):
            validate_and_project_manifest(duplicate_action, path, known_ids)

    def test_rejects_duplicate_dynamic_template_ids(self) -> None:
        path = PLUGINS_ROOT / "AppVolume" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        provider = manifest["actions"]["providers"][0]
        provider["dynamicTemplates"].append(copy.deepcopy(provider["dynamicTemplates"][0]))

        with self.assertRaisesRegex(ManifestValidationError, "duplicates an action or template key"):
            validate_and_project_manifest(manifest, path, load_known_plugin_ids(PLUGINS_ROOT))

    def test_parameterless_static_action_rejects_parameter_summary(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        action = manifest["actions"]["providers"][0]["staticActions"][0]
        action["parameterSummary"] = action["description"]

        with self.assertRaisesRegex(ManifestValidationError, "without parameters"):
            validate_and_project_manifest(manifest, path, load_known_plugin_ids(PLUGINS_ROOT))

    def test_dynamic_template_rejects_repeated_parameter_summary(self) -> None:
        path = PLUGINS_ROOT / "AppHotkey" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        template = manifest["actions"]["providers"][0]["dynamicTemplates"][0]
        template["parameterSummary"] = template["description"]
        del manifest["productStrings"]["action.launch.parameter-summary"]

        with self.assertRaisesRegex(ManifestValidationError, "must describe the template parameters"):
            validate_and_project_manifest(manifest, path, load_known_plugin_ids(PLUGINS_ROOT))

    def test_guided_setup_rejects_product_metadata_placeholder(self) -> None:
        path = PLUGINS_ROOT / "Calendar" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        step = manifest["setup"]["steps"][0]
        step["title"] = "@productStrings.display-name"
        step["description"] = "@productStrings.summary"
        del manifest["productStrings"]["setup.requirements.title"]
        del manifest["productStrings"]["setup.requirements.description"]

        with self.assertRaisesRegex(ManifestValidationError, "concrete setup requirements"):
            validate_and_project_manifest(manifest, path, load_known_plugin_ids(PLUGINS_ROOT))

    def test_multi_action_providers_publish_distinct_localized_copy(self) -> None:
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        for path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(path.read_text(encoding="utf-8"))
            projected, _ = validate_and_project_manifest(manifest, path, known_ids)
            for provider in projected.get("actions", {}).get("providers", []):
                entries = provider["staticActions"] + provider["dynamicTemplates"]
                if len(entries) < 2:
                    continue
                for field in ("title", "description", "parameterSummary"):
                    field_entries = [entry for entry in entries if field in entry]
                    if len(field_entries) < 2:
                        continue
                    for locale in SUPPORTED_LOCALES:
                        values = [entry[field][locale] for entry in field_entries]
                        with self.subTest(
                            plugin=manifest["id"],
                            provider=provider["id"],
                            field=field,
                            locale=locale,
                        ):
                            self.assertEqual(len(values), len(set(values)))

    def test_rejects_action_surfaces_that_runtime_policy_cannot_expose(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        confirmation = copy.deepcopy(manifest)
        confirmation["actions"]["providers"][0]["staticActions"][0]["risk"] = "confirmationRequired"
        with self.assertRaisesRegex(ManifestValidationError, "automatic-rule requires"):
            validate_and_project_manifest(confirmation, path, known_ids)

        local_only = copy.deepcopy(manifest)
        action = local_only["actions"]["providers"][0]["staticActions"][0]
        action["parameters"] = [{
            "id": "device", "kind": "string", "isRequired": True, "portability": "localOnly",
        }]
        with self.assertRaisesRegex(ManifestValidationError, "app-intent requires"):
            validate_and_project_manifest(local_only, path, known_ids)

        missing_run_link = copy.deepcopy(manifest)
        action = missing_run_link["actions"]["providers"][0]["staticActions"][0]
        action["surfaces"].remove("run-link")
        with self.assertRaisesRegex(ManifestValidationError, "run-link must match"):
            validate_and_project_manifest(missing_run_link, path, known_ids)

        shortcuts_path = PLUGINS_ROOT / "AppleShortcuts" / "plugin.json"
        for surface in ("automatic-rule", "app-intent"):
            shortcuts = json.loads(shortcuts_path.read_text(encoding="utf-8"))
            shortcuts["actions"]["providers"][0]["dynamicTemplates"][0]["surfaces"].append(
                surface
            )
            with self.subTest(surface=surface), self.assertRaisesRegex(
                ManifestValidationError,
                f"{surface} requires",
            ):
                validate_and_project_manifest(shortcuts, shortcuts_path, known_ids)

        saved_scripts_path = PLUGINS_ROOT / "SavedScripts" / "plugin.json"
        saved_scripts = json.loads(saved_scripts_path.read_text(encoding="utf-8"))
        saved_scripts["actions"]["providers"][0]["dynamicTemplates"][0]["surfaces"].append(
            "app-intent"
        )
        with self.assertRaisesRegex(ManifestValidationError, "app-intent requires"):
            validate_and_project_manifest(saved_scripts, saved_scripts_path, known_ids)

    def test_rejects_values_that_do_not_match_the_catalog_codable_shape(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        mutations = [
            ("publisher", lambda value: value["presentation"].__setitem__("publisher", 7)),
            ("requiresRelaunch", lambda value: value["requirements"].__setitem__("requiresRelaunch", "false")),
            ("applications", lambda value: value["requirements"].__setitem__(
                "applications", [{"bundleID": 7, "name": "Example"}]
            )),
            ("processesSensitiveUserContent", lambda value: value["privacy"].__setitem__(
                "processesSensitiveUserContent", "false"
            )),
        ]

        for field, mutate in mutations:
            invalid = copy.deepcopy(manifest)
            mutate(invalid)
            with self.subTest(field=field):
                with self.assertRaisesRegex(ManifestValidationError, field):
                    validate_and_project_manifest(invalid, path, known_ids)

    def test_static_dynamic_and_mixed_provider_shapes_validate(self) -> None:
        appearance_path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        app_volume_path = PLUGINS_ROOT / "AppVolume" / "plugin.json"
        appearance = json.loads(appearance_path.read_text(encoding="utf-8"))
        app_volume = json.loads(app_volume_path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        validate_and_project_manifest(appearance, appearance_path, known_ids)
        validate_and_project_manifest(app_volume, app_volume_path, known_ids)

        mixed = copy.deepcopy(appearance)
        provider = mixed["actions"]["providers"][0]
        provider["kind"] = "mixed"
        template = copy.deepcopy(
            app_volume["actions"]["providers"][0]["dynamicTemplates"][0]
        )
        template["id"] = "set-device-value"
        provider["dynamicTemplates"] = [template]
        mixed["permissions"].append("system-audio-recording")
        mixed["requirements"]["permissionIDs"].append("system-audio-recording")
        for field in ("title", "description", "parameterSummary"):
            key = template[field].removeprefix("@productStrings.")
            mixed["productStrings"][key] = app_volume["productStrings"][key]

        validate_and_project_manifest(mixed, appearance_path, known_ids)

    def test_rejects_invalid_action_permission_relationship_asset_and_test_action(self) -> None:
        path = PLUGINS_ROOT / "Appearance" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)

        cases = []
        invalid_key = copy.deepcopy(manifest)
        invalid_key["actions"]["providers"][0]["staticActions"][0]["id"] = "bad/action"
        cases.append((invalid_key, "stable identifier"))

        invalid_permission = copy.deepcopy(manifest)
        invalid_permission["actions"]["providers"][0]["staticActions"][0]["permissionIDs"] = ["root-access"]
        cases.append((invalid_permission, "unknown: root-access"))

        invalid_relationship = copy.deepcopy(manifest)
        invalid_relationship["relationships"]["relatedPluginIDs"] = ["missing-plugin"]
        cases.append((invalid_relationship, "references unknown plugins"))

        invalid_asset = copy.deepcopy(manifest)
        invalid_asset["presentation"]["screenshots"] = [{
            "id": "missing",
            "path": "MarketplaceAssets/missing.png",
            "alt": invalid_asset["presentation"]["longDescription"],
        }]
        cases.append((invalid_asset, "asset does not exist"))

        invalid_test_action = copy.deepcopy(manifest)
        invalid_test_action["setup"]["suggestedTestAction"]["actionID"] = "missing"
        cases.append((invalid_test_action, "must reference a declared static action"))

        for value, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ManifestValidationError, message):
                    validate_and_project_manifest(value, path, known_ids)

    def test_unknown_optional_field_is_preserved_and_dynamic_templates_must_be_complete(self) -> None:
        path = PLUGINS_ROOT / "AppVolume" / "plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        known_ids = load_known_plugin_ids(PLUGINS_ROOT)
        manifest["futureProductField"] = {"enabled": True}

        projected, _ = validate_and_project_manifest(manifest, path, known_ids)

        self.assertEqual(projected["futureProductField"], {"enabled": True})

        incomplete = copy.deepcopy(manifest)
        template = incomplete["actions"]["providers"][0]["dynamicTemplates"][0]
        key = template["parameterSummary"].removeprefix("@productStrings.")
        del template["parameterSummary"]
        del incomplete["productStrings"][key]
        with self.assertRaisesRegex(ManifestValidationError, "missing parameterSummary"):
            validate_and_project_manifest(incomplete, path, known_ids)

    def test_asset_projection_hashes_and_validates_png(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            asset = root / "MarketplaceAssets" / "preview.png"
            asset.parent.mkdir()
            asset.write_bytes(base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlS8AAAAASUVORK5CYII="
            ))
            localized = {locale: "Preview" for locale in SUPPORTED_LOCALES}
            manifest = {
                "id": "asset-demo",
                "displayName": "Asset Demo",
                "version": "1.0.0",
                "minHostVersion": "1.2.0",
                "pluginKitVersion": 5,
                "bundleRelativePath": "AssetDemo.bundle",
                "capabilities": {
                    "primaryPanel": False,
                    "componentPanel": False,
                    "settings": "none",
                },
                "permissions": [],
                "category": "other",
                "productStrings": {"preview": localized},
                "presentation": {
                    "longDescription": "@productStrings.preview",
                    "examples": [],
                    "screenshots": [{
                        "id": "main",
                        "path": "MarketplaceAssets/preview.png",
                        "alt": "@productStrings.preview",
                    }],
                    "publisher": "Example",
                    "license": "Apache-2.0",
                },
            }
            path = root / "plugin.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")

            projected, assets = validate_and_project_manifest(manifest, path, {"asset-demo"})

            screenshot = projected["presentation"]["screenshots"][0]
            self.assertEqual(screenshot["mediaType"], "image/png")
            self.assertEqual(screenshot["width"], 1)
            self.assertEqual(screenshot["height"], 1)
            self.assertEqual(len(screenshot["sha256"]), 64)
            self.assertEqual(len(assets), 1)

    def test_assets_cannot_escape_root_or_bypass_dimension_parsing(self) -> None:
        localized = {locale: "Preview" for locale in SUPPORTED_LOCALES}

        def manifest_for(path: str) -> dict:
            return {
                "id": "asset-demo",
                "displayName": "Asset Demo",
                "version": "1.0.0",
                "minHostVersion": "1.2.0",
                "pluginKitVersion": 5,
                "bundleRelativePath": "AssetDemo.bundle",
                "capabilities": {
                    "primaryPanel": False,
                    "componentPanel": False,
                    "settings": "none",
                },
                "permissions": [],
                "category": "other",
                "productStrings": {"preview": localized},
                "presentation": {
                    "longDescription": "@productStrings.preview",
                    "examples": [],
                    "screenshots": [{
                        "id": "main",
                        "path": path,
                        "alt": "@productStrings.preview",
                    }],
                    "publisher": "Example",
                    "license": "Apache-2.0",
                },
            }

        with tempfile.TemporaryDirectory() as temporary_directory:
            parent = pathlib.Path(temporary_directory)
            root = parent / "Plugin"
            assets = root / "MarketplaceAssets"
            assets.mkdir(parents=True)
            outside = parent / "outside.png"
            outside.write_bytes(base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlS8AAAAASUVORK5CYII="
            ))
            (assets / "linked.png").symlink_to(outside)
            path = root / "plugin.json"
            manifest = manifest_for("MarketplaceAssets/linked.png")

            with self.assertRaisesRegex(ManifestValidationError, "resolve inside"):
                validate_and_project_manifest(manifest, path, {"asset-demo"})

            corrupt = assets / "corrupt.png"
            corrupt.write_bytes(b"\x89PNG\r\n\x1a\n")
            manifest = manifest_for("MarketplaceAssets/corrupt.png")
            with self.assertRaisesRegex(ManifestValidationError, "dimensions could not be parsed"):
                validate_and_project_manifest(manifest, path, {"asset-demo"})

            oversized_webp = assets / "oversized.webp"
            width_minus_one = 8_000 - 1
            payload = b"\0\0\0\0" + width_minus_one.to_bytes(3, "little") + (0).to_bytes(3, "little")
            body = b"WEBP" + b"VP8X" + len(payload).to_bytes(4, "little") + payload
            oversized_webp.write_bytes(b"RIFF" + len(body).to_bytes(4, "little") + body)
            manifest = manifest_for("MarketplaceAssets/oversized.webp")
            with self.assertRaisesRegex(ManifestValidationError, "dimensions must not exceed"):
                validate_and_project_manifest(manifest, path, {"asset-demo"})

    def test_catalog_and_website_generation_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            package = root / "appearance.mactoolsplugin"
            package.mkdir()
            source = PLUGINS_ROOT / "Appearance" / "plugin.json"
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_ROOT / "copy-plugin-manifest.py"),
                    "copy",
                    "--source", str(source),
                    "--destination", str(package / "plugin.json"),
                    "--configuration", "Release",
                    "--app-version-config", str(REPO_ROOT / "Configs/AppVersion.xcconfig"),
                ],
                check=True,
            )
            package.joinpath("Appearance.bundle").mkdir()
            package.joinpath("Appearance.bundle", "payload").write_text("fixture", encoding="utf-8")
            first_catalog = root / "first.json"
            second_catalog = root / "second.json"
            first_website = root / "first-website" / "plugins.json"
            second_website = root / "second-website" / "plugins.json"
            base_command = [
                sys.executable,
                str(SCRIPTS_ROOT / "generate-plugin-catalog.py"),
                "--mode", "debug",
                "--package", str(package),
                "--plugins-root", str(PLUGINS_ROOT),
                "--generated-at", "2026-08-23T00:00:00Z",
            ]
            subprocess.run(
                base_command + ["--output", str(first_catalog), "--website-output", str(first_website)],
                check=True,
            )
            subprocess.run(
                base_command + ["--output", str(second_catalog), "--website-output", str(second_website)],
                check=True,
            )

            self.assertEqual(first_catalog.read_bytes(), second_catalog.read_bytes())
            self.assertEqual(first_website.read_bytes(), second_website.read_bytes())
            self.assertNotIn("@summary", first_catalog.read_text(encoding="utf-8"))
            self.assertNotIn("@displayName", first_catalog.read_text(encoding="utf-8"))
            self.assertNotIn("@productStrings", first_catalog.read_text(encoding="utf-8"))
            catalog = json.loads(first_catalog.read_text(encoding="utf-8"))
            self.assertEqual(catalog["schemaVersion"], 3)
            self.assertEqual(catalog["minimumHostVersion"], "0.1.0")
            entry = catalog["plugins"][0]
            self.assertIn("actions", entry)
            self.assertNotIn("build", entry)
            self.assertNotIn("productStrings", entry)
            website = json.loads(first_website.read_text(encoding="utf-8"))
            self.assertNotIn("package", website["plugins"][0])

            release_catalog = root / "release.json"
            release_command = list(base_command)
            release_command[release_command.index("debug")] = "release"
            subprocess.run(
                release_command + [
                    "--base-url", "https://example.com/plugins",
                    "--output", str(release_catalog),
                ],
                check=True,
            )
            self.assertEqual(
                json.loads(release_catalog.read_text(encoding="utf-8"))["minimumHostVersion"],
                "1.2.1",
            )
            incompatible_release = subprocess.run(
                release_command + [
                    "--base-url", "https://example.com/plugins",
                    "--minimum-host-version", "1.2.0",
                    "--output", str(root / "incompatible-release.json"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(incompatible_release.returncode, 0)
            self.assertIn("require MacTools 1.2.1", incompatible_release.stderr)

    def test_dynamic_catalog_template_never_contains_machine_local_entries(self) -> None:
        manifest = json.loads(
            (PLUGINS_ROOT / "AppVolume" / "plugin.json").read_text(encoding="utf-8")
        )
        provider = manifest["actions"]["providers"][0]

        self.assertEqual(provider["kind"], "dynamic")
        self.assertEqual(provider["staticActions"], [])
        self.assertEqual(provider["dynamicTemplates"][0]["entrySource"], "active-audio-applications")
        self.assertNotIn("entries", provider)


if __name__ == "__main__":
    unittest.main()
