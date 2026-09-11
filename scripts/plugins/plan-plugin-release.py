#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_SHARED_PATHS = ["Sources/MacToolsPluginKit"]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Plan an incremental MacTools plugin release."
    )
    parser.add_argument("--mode", choices=["auto", "all", "selected"], default="auto")
    parser.add_argument("--plugins", default="", help="Comma-separated plugin IDs for selected mode.")
    parser.add_argument("--plugin", action="append", default=[], help="Plugin ID or directory name. Repeatable.")
    parser.add_argument("--source-dir", default="Plugins")
    parser.add_argument("--previous-catalog", default="docs/plugins/catalog.json")
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--require-version-bump",
        action="store_true",
        help=(
            "Require every plugin already present in the previous catalog to use a "
            "strictly newer version. Intended for full compatibility-line migrations."
        ),
    )
    parser.add_argument(
        "--shared-path",
        action="append",
        default=[],
        help=(
            "Repository path that forces existing plugins to rebuild when changed. "
            "Repeatable; added to the default PluginKit shared path."
        ),
    )
    return parser.parse_args()


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None


def git(args, check=True, capture=True):
    kwargs = {
        "check": check,
        "text": True,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    return subprocess.run(["git", *args], **kwargs)


def git_ref_exists(ref):
    return git(["rev-parse", "--verify", "--quiet", ref], check=False).returncode == 0


def changed_paths(ref, paths):
    existing_paths = [path for path in paths if path]
    if not existing_paths:
        return []
    result = git(["diff", "--name-only", f"{ref}..HEAD", "--", *existing_paths])
    return [line for line in result.stdout.splitlines() if line.strip()]


def package_relevant_plugin_paths(paths):
    result = []
    for path in paths:
        parts = Path(path).parts
        if "Tests" in parts:
            continue
        result.append(path)
    return result


def version_parts(version):
    values = []
    for component in version.split("."):
        match = re.match(r"(\d+)", component)
        values.append(int(match.group(1)) if match else 0)
    return values


def compare_versions(lhs, rhs):
    left = version_parts(lhs)
    right = version_parts(rhs)
    count = max(len(left), len(right))
    left.extend([0] * (count - len(left)))
    right.extend([0] * (count - len(right)))
    if left < right:
        return -1
    if left > right:
        return 1
    return 0


def plugin_release_tag(entry):
    candidates = [
        ((entry.get("package") or {}).get("url") or ""),
        entry.get("releaseNotesURL") or "",
    ]
    for value in candidates:
        match = re.search(r"/releases/(?:download|tag)/([^/]+)", value)
        if match:
            return match.group(1)
    return None


def read_plugins(source_dir):
    root = Path(source_dir)
    plugins = {}
    for manifest_path in sorted(root.glob("*/plugin.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        plugin_id = manifest["id"]
        plugins[plugin_id] = {
            "id": plugin_id,
            "directoryName": manifest_path.parent.name,
            "path": manifest_path.parent.as_posix(),
            "manifestPath": manifest_path.as_posix(),
            "version": manifest["version"],
            "pluginKitVersion": manifest["pluginKitVersion"],
            "displayName": manifest.get("displayName", plugin_id),
        }
    return plugins


def current_plugin_kit_version(plugins):
    versions = sorted({plugin["pluginKitVersion"] for plugin in plugins.values()})
    if len(versions) != 1:
        raise SystemExit(
            "Plugin manifests must use one pluginKitVersion for a release: "
            + ", ".join(str(version) for version in versions)
        )
    return versions[0]


def normalize_selected(raw_values, plugins):
    values = []
    for raw in raw_values:
        values.extend(part.strip() for part in raw.split(",") if part.strip())

    by_directory = {plugin["directoryName"]: plugin_id for plugin_id, plugin in plugins.items()}
    selected = []
    unknown = []
    for value in values:
        plugin_id = value if value in plugins else by_directory.get(value)
        if plugin_id is None:
            unknown.append(value)
        elif plugin_id not in selected:
            selected.append(plugin_id)
    return selected, unknown


def plan_release(args):
    if args.require_version_bump and args.mode != "all":
        raise SystemExit("--require-version-bump requires --mode all")

    plugins = read_plugins(args.source_dir)
    plugin_kit_version = current_plugin_kit_version(plugins)
    previous_catalog = load_json(args.previous_catalog)
    previous_catalog_plugin_kit_version = (previous_catalog or {}).get("pluginKitVersion")
    previous_entries = {
        entry["id"]: entry
        for entry in (previous_catalog or {}).get("plugins", [])
    }
    shared_paths = list(dict.fromkeys([*DEFAULT_SHARED_PATHS, *args.shared_path]))
    selected_inputs, unknown_inputs = normalize_selected(
        [args.plugins, *args.plugin],
        plugins,
    )

    if unknown_inputs:
        raise SystemExit("Unknown plugin selection: " + ", ".join(unknown_inputs))

    removed_plugin_ids = []
    if args.mode != "selected":
        removed_plugin_ids = sorted(set(previous_entries) - set(plugins))
    selected = []
    reasons = {}
    errors = []
    full_release = False

    if (
        previous_catalog_plugin_kit_version is not None
        and previous_catalog_plugin_kit_version != plugin_kit_version
    ):
        # A catalog must never mix packages built against different PluginKit
        # ABIs. The first release of a new ABI therefore replaces the entire
        # catalog, even when the caller selected the default auto mode.
        full_release = True

    def select(plugin_id, reason):
        if plugin_id not in selected:
            selected.append(plugin_id)
        reasons.setdefault(plugin_id, []).append(reason)

    def previous_entry_plugin_kit_version(entry):
        if "pluginKitVersion" in entry:
            return entry["pluginKitVersion"]
        if previous_catalog_plugin_kit_version is not None:
            return previous_catalog_plugin_kit_version
        raise SystemExit(
            f"Previous catalog entry is missing pluginKitVersion: {entry.get('id', '(unknown)')}"
        )

    def handle_plugin_kit_change(plugin_id, plugin, previous_entry, version_cmp):
        previous_version = previous_entry_plugin_kit_version(previous_entry)
        if previous_version == plugin["pluginKitVersion"]:
            return False

        reason = f"pluginKitVersion {previous_version} -> {plugin['pluginKitVersion']}"
        if version_cmp <= 0:
            errors.append(
                f"{plugin_id}: {reason}, but version is still {plugin['version']}. "
                f"Bump {plugin['manifestPath']} version before publishing a PluginKit update."
            )
        else:
            select(plugin_id, reason)
        return True

    if (
        args.mode == "selected"
        and previous_catalog_plugin_kit_version is not None
        and previous_catalog_plugin_kit_version != plugin_kit_version
        and set(selected_inputs) != set(plugins)
    ):
        errors.append(
            "Current pluginKitVersion differs from the previous catalog "
            f"({previous_catalog_plugin_kit_version} -> {plugin_kit_version}). "
            "Use --mode all so the catalog cannot mix incompatible plugin packages."
        )

    if args.mode == "selected" and set(selected_inputs) != set(plugins):
        shared_change_samples = []
        unverifiable_plugins = []
        for plugin_id in sorted(set(plugins) - set(selected_inputs)):
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                continue
            tag = plugin_release_tag(previous_entry)
            if not tag or not git_ref_exists(tag):
                unverifiable_plugins.append(plugin_id)
                continue
            shared_change_samples.extend(changed_paths(tag, shared_paths))
        shared_change_samples = sorted(set(shared_change_samples))
        if shared_change_samples:
            errors.append(
                "Selected mode cannot publish only part of the catalog after shared "
                "PluginKit sources changed. Use --mode all so every package is rebuilt. "
                "Changed paths: " + ", ".join(shared_change_samples[:5])
            )
        elif unverifiable_plugins:
            errors.append(
                "Selected mode cannot verify the shared PluginKit baseline for: "
                + ", ".join(unverifiable_plugins)
                + ". Use --mode all so every package is rebuilt."
            )

    if args.mode == "all":
        full_release = True
        for plugin_id, plugin in sorted(plugins.items()):
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is not None:
                previous_version = previous_entry["version"]
                current_version = plugin["version"]
                version_cmp = compare_versions(current_version, previous_version)
                if version_cmp < 0:
                    errors.append(
                        f"{plugin_id}: version cannot go backwards "
                        f"({previous_version} -> {current_version})"
                    )
                    continue
                if args.require_version_bump and version_cmp == 0:
                    errors.append(
                        f"{plugin_id}: compatibility migration requires a version bump "
                        f"above {previous_version}. Bump {plugin['manifestPath']} version "
                        "before publishing the full rebuild."
                    )
                    continue
                handle_plugin_kit_change(plugin_id, plugin, previous_entry, version_cmp)
            select(plugin_id, "all mode")
    elif args.mode == "selected":
        if not selected_inputs:
            raise SystemExit("--mode selected requires --plugins or --plugin")
        for plugin_id in selected_inputs:
            select(plugin_id, "selected mode")
        for plugin_id in selected_inputs:
            plugin = plugins[plugin_id]
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                continue

            previous_version = previous_entry["version"]
            current_version = plugin["version"]
            version_cmp = compare_versions(current_version, previous_version)
            if version_cmp < 0:
                errors.append(
                    f"{plugin_id}: version cannot go backwards "
                    f"({previous_version} -> {current_version})"
                )
                continue

            handle_plugin_kit_change(plugin_id, plugin, previous_entry, version_cmp)
    elif not previous_catalog:
        full_release = True
        for plugin_id in sorted(plugins):
            select(plugin_id, "no previous catalog")
    else:
        for plugin_id, plugin in sorted(plugins.items()):
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                select(plugin_id, "new plugin")
                continue

            previous_version = previous_entry["version"]
            current_version = plugin["version"]
            version_cmp = compare_versions(current_version, previous_version)
            if version_cmp < 0:
                errors.append(
                    f"{plugin_id}: version cannot go backwards "
                    f"({previous_version} -> {current_version})"
                )
                continue
            if handle_plugin_kit_change(plugin_id, plugin, previous_entry, version_cmp):
                continue
            if version_cmp > 0:
                select(plugin_id, f"version {previous_version} -> {current_version}")
                continue

            tag = plugin_release_tag(previous_entry)
            if not tag:
                errors.append(f"{plugin_id}: previous release tag could not be inferred from catalog")
                continue
            if not git_ref_exists(tag):
                errors.append(f"{plugin_id}: previous release tag is not available locally: {tag}")
                continue

            plugin_changes = package_relevant_plugin_paths(changed_paths(tag, [plugin["path"]]))
            shared_changes = changed_paths(tag, shared_paths)
            if plugin_changes or shared_changes:
                if version_cmp <= 0:
                    change_samples = (plugin_changes + shared_changes)[:5]
                    errors.append(
                        f"{plugin_id}: package-relevant files changed since {tag}, "
                        f"but version is still {current_version}. "
                        f"Bump {plugin['manifestPath']} version. Changed paths: "
                        + ", ".join(change_samples)
                    )
                else:
                    select(plugin_id, f"package-relevant changes since {tag}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)

    selected = sorted(selected)
    plan = {
        "mode": args.mode,
        "releaseRequired": bool(selected or removed_plugin_ids),
        "fullRelease": full_release,
        "pluginKitVersion": plugin_kit_version,
        "selectedPluginIDs": selected,
        "removedPluginIDs": removed_plugin_ids,
        "reasons": {plugin_id: reasons.get(plugin_id, []) for plugin_id in selected},
        "plugins": [
            {
                "id": plugin_id,
                "displayName": plugins[plugin_id]["displayName"],
                "version": plugins[plugin_id]["version"],
                "path": plugins[plugin_id]["path"],
            }
            for plugin_id in selected
        ],
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return plan


def main():
    args = parse_args()
    plan = plan_release(args)
    if plan["selectedPluginIDs"]:
        print("Selected plugins: " + ", ".join(plan["selectedPluginIDs"]))
    elif plan["removedPluginIDs"]:
        print("No plugin packages selected; removed plugins: " + ", ".join(plan["removedPluginIDs"]))
    else:
        print("No plugin release changes detected.")


if __name__ == "__main__":
    main()
