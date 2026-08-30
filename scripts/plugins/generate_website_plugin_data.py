#!/usr/bin/env python3
"""Generate deterministic Astro plugin data from validated source manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from plugin_source_manifest import (  # noqa: E402
    ManifestValidationError,
    SUPPORTED_LOCALE_ORDER,
    load_known_plugin_ids,
    validate_and_project_manifest,
)

GENERATOR_VERSION = 1


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def mac_tools_url(plugin_id: str, provider_id: str | None = None, action_id: str | None = None) -> str:
    if (provider_id is None) != (action_id is None):
        raise ValueError("provider_id and action_id must be supplied together")
    url = f"mactools://app/settings/plugins/marketplace/{plugin_id}"
    if provider_id is not None and action_id is not None:
        return f"{url}?provider={provider_id}&action={action_id}"
    return url


def project_manifests(plugins_root: Path) -> dict[str, object]:
    known_ids = load_known_plugin_ids(plugins_root)
    plugins: list[dict] = []
    actions: list[dict] = []
    search: list[dict] = []
    assets: list[dict] = []
    routes: list[dict] = []
    action_paths: set[str] = set()

    for manifest_path in sorted(plugins_root.glob("*/plugin.json")):
        source = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest, source_assets = validate_and_project_manifest(source, manifest_path, known_ids)
        plugin_id = manifest["id"]
        product = {key: manifest.get(key) for key in (
            "presentation", "discovery", "requirements", "privacy", "actions", "setup", "relationships"
        )}
        plugin = {
            "id": plugin_id,
            "displayName": manifest["displayName"],
            "summary": manifest["summary"],
            "localizedMetadata": manifest["localizedMetadata"],
            "version": manifest["version"],
            "category": manifest.get("category"),
            "releaseChannel": manifest.get("releaseChannel"),
            "releaseNotesURL": manifest.get("releaseNotesURL"),
            "capabilities": manifest["capabilities"],
            "product": product,
            "openInMacToolsURL": mac_tools_url(plugin_id),
            "route": f"/plugins/{plugin_id}/",
        }
        plugins.append(plugin)
        routes.append({"kind": "plugin", "path": plugin["route"], "pluginID": plugin_id})

        discovery = product.get("discovery") or {}
        actions_metadata = product.get("actions") or {}
        localized_metadata = manifest["localizedMetadata"]
        localized_synonyms = discovery.get("localizedSynonyms", {})
        localized_search = {
            locale: {
                "title": localized_metadata.get(locale, {}).get("displayName", manifest["displayName"]),
                "summary": localized_metadata.get(locale, {}).get("summary", manifest["summary"]),
                "keywords": sorted(set(discovery.get("keywords", []) + localized_synonyms.get(locale, []))),
            }
            for locale in SUPPORTED_LOCALE_ORDER
        }
        search.append({
            "kind": "plugin", "pluginID": plugin_id, "title": manifest["displayName"],
            "summary": manifest["summary"], "keywords": localized_search["en"]["keywords"],
            "localized": localized_search, "route": plugin["route"],
        })
        for provider in actions_metadata.get("providers", []):
            for action in provider.get("staticActions", []):
                path = f"/plugins/{plugin_id}/actions/{provider['id']}/{action['id']}/"
                if path in action_paths:
                    raise ManifestValidationError(f"{plugin_id}: website route collision: {path}")
                action_paths.add(path)
                projected = {
                    "pluginID": plugin_id, "providerID": provider["id"], "action": action,
                    "route": path,
                    "openInMacToolsURL": mac_tools_url(plugin_id, provider["id"], action["id"]),
                }
                actions.append(projected)
                routes.append({"kind": "action", "path": path, "pluginID": plugin_id, "providerID": provider["id"], "actionID": action["id"]})
                search.append({
                    "kind": "action", "pluginID": plugin_id, "providerID": provider["id"], "actionID": action["id"],
                    "title": action["title"], "summary": action["description"],
                    "keywords": sorted(set(action["keywords"])), "route": path,
                })
        for source_asset in source_assets:
            suffix = source_asset.source.suffix.lower()
            filename = f"{source_asset.catalog['sha256']}{suffix}"
            assets.append({**source_asset.catalog, "outputPath": f"/generated/plugin-assets/{filename}", "source": str(source_asset.source)})

    plugins.sort(key=lambda item: item["id"])
    actions.sort(key=lambda item: (item["pluginID"], item["providerID"], item["action"]["id"]))
    routes.sort(key=lambda item: item["path"])
    search.sort(key=lambda item: (item["kind"], item["pluginID"], item.get("providerID", ""), item.get("actionID", "")))
    assets.sort(key=lambda item: item["outputPath"])
    return {"generatorVersion": GENERATOR_VERSION, "plugins": plugins, "actions": actions, "search": search, "routes": routes, "assets": assets}


def write_or_check(path: Path, contents: bytes, check: bool) -> bool:
    if path.is_file() and path.read_bytes() == contents:
        return True
    if check:
        print(f"stale generated output: {path}", file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents)
    return True


def generate(repo_root: Path, output_dir: Path, assets_dir: Path, check: bool) -> bool:
    data = project_manifests(repo_root / "Plugins")
    outputs = {
        "plugins.json": {"generatorVersion": GENERATOR_VERSION, "plugins": data["plugins"]},
        "actions.json": {"generatorVersion": GENERATOR_VERSION, "actions": data["actions"]},
        "search-index.json": {"generatorVersion": GENERATOR_VERSION, "entries": data["search"]},
        "routes.json": {"generatorVersion": GENERATOR_VERSION, "routes": data["routes"]},
        "assets.json": {"generatorVersion": GENERATOR_VERSION, "assets": [{k: v for k, v in asset.items() if k != "source"} for asset in data["assets"]]},
    }
    is_current = all(write_or_check(output_dir / name, canonical_json(value), check) for name, value in outputs.items())
    expected_asset_names = {Path(asset["outputPath"]).name for asset in data["assets"]}
    if assets_dir.exists():
        unexpected_assets = sorted(path for path in assets_dir.iterdir() if path.is_file() and path.name not in expected_asset_names)
        for path in unexpected_assets:
            if check:
                print(f"stale generated asset: {path}", file=sys.stderr)
                is_current = False
            else:
                path.unlink()
    for asset in data["assets"]:
        destination = assets_dir / Path(asset["outputPath"]).name
        source = Path(asset["source"])
        if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == asset["sha256"]:
            continue
        if check:
            print(f"stale generated asset: {destination}", file=sys.stderr)
            is_current = False
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    return is_current


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=SCRIPT_DIR.parents[1])
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--assets-dir", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.repo_root.resolve()
    output = (args.output_dir or root / "site" / "src" / "generated").resolve()
    assets = (args.assets_dir or root / "site" / "public" / "generated" / "plugin-assets").resolve()
    try:
        return 0 if generate(root, output, assets, args.check) else 1
    except (ManifestValidationError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
