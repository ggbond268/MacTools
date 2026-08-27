#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_CATALOG_ID = "com.ggbond.mactools.plugins"
DEFAULT_MINIMUM_HOST_VERSION = "1.1.6"
SCHEMA3_MINIMUM_HOST_VERSION = "1.2.1"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Merge newly built plugin catalog entries into the current production catalog."
    )
    parser.add_argument("--previous", default="docs/plugins/catalog.json")
    parser.add_argument("--updates", required=True)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--plugin-kit-version", type=int, required=True)
    parser.add_argument(
        "--minimum-host-version",
        help="Override the merged catalog host floor for a host-specific endpoint.",
    )
    return parser.parse_args()


def load_json(path, required=True):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        if required:
            raise
        return None


def unsigned(catalog):
    if catalog is None:
        return None
    result = dict(catalog)
    result.pop("signature", None)
    return result


def update_field(previous, updates, key, default=None):
    if updates is not None and key in updates:
        return updates[key]
    if previous is not None and key in previous:
        return previous[key]
    return default


def now_iso8601():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def main():
    args = parse_args()
    previous = unsigned(load_json(args.previous, required=False))
    plan = load_json(args.plan)

    selected_ids = plan.get("selectedPluginIDs", [])
    removed_ids = plan.get("removedPluginIDs", [])
    updates_required = bool(selected_ids)
    updates = unsigned(load_json(args.updates, required=updates_required))

    if previous is None and updates is None:
        raise SystemExit("No previous catalog or update catalog is available.")

    update_entries = {
        entry["id"]: entry
        for entry in (updates or {}).get("plugins", [])
    }
    missing_updates = sorted(plugin_id for plugin_id in selected_ids if plugin_id not in update_entries)
    if missing_updates:
        raise SystemExit(
            "Update catalog is missing selected plugin entries: "
            + ", ".join(missing_updates)
        )

    full_release = bool(plan.get("fullRelease"))
    if full_release:
        if not update_entries:
            raise SystemExit("A full catalog release requires a non-empty update catalog.")
        merged_entries = update_entries
        base_catalog = updates
    else:
        merged_entries = {
            entry["id"]: entry
            for entry in (previous or {}).get("plugins", [])
        }

        for plugin_id in removed_ids:
            merged_entries.pop(plugin_id, None)

        for plugin_id in selected_ids:
            merged_entries[plugin_id] = update_entries[plugin_id]
        base_catalog = previous or updates

    schema_version = update_field(base_catalog, updates, "schemaVersion", 3)
    plugin_kit_version = update_field(base_catalog, updates, "pluginKitVersion", args.plugin_kit_version)
    if plugin_kit_version != args.plugin_kit_version:
        raise SystemExit(
            "Merged catalog pluginKitVersion does not match the expected release version "
            f"({plugin_kit_version} != {args.plugin_kit_version})."
        )
    incompatible_entries = sorted(
        entry["id"]
        for entry in merged_entries.values()
        if entry.get("pluginKitVersion", plugin_kit_version) != plugin_kit_version
    )
    if incompatible_entries:
        raise SystemExit(
            "Merged catalog would mix pluginKitVersion values. "
            "Rebuild these plugins for the current PluginKit: "
            + ", ".join(incompatible_entries)
        )

    minimum_host_version = args.minimum_host_version or min(
        (
            value
            for value in [
                (previous or {}).get("minimumHostVersion"),
                (updates or {}).get("minimumHostVersion"),
            ]
            if value
        ),
        key=version_tuple,
        default=(
            SCHEMA3_MINIMUM_HOST_VERSION
            if schema_version >= 3
            else DEFAULT_MINIMUM_HOST_VERSION
        ),
    )
    if schema_version >= 3 and version_tuple(minimum_host_version) < version_tuple(
        SCHEMA3_MINIMUM_HOST_VERSION
    ):
        if args.minimum_host_version:
            raise SystemExit(
                "Schema 3 catalogs require minimumHostVersion "
                f"{SCHEMA3_MINIMUM_HOST_VERSION} or later."
            )
        minimum_host_version = SCHEMA3_MINIMUM_HOST_VERSION

    catalog = {
        "schemaVersion": schema_version,
        "catalogID": update_field(base_catalog, updates, "catalogID", DEFAULT_CATALOG_ID),
        "generatedAt": now_iso8601(),
        # The catalog floor describes schema compatibility. Per-entry host
        # requirements may be newer and are enforced by each client.
        "minimumHostVersion": minimum_host_version,
        "pluginKitVersion": plugin_kit_version,
        "plugins": sorted(merged_entries.values(), key=lambda entry: entry["id"]),
        "revoked": update_field(base_catalog, updates, "revoked", []),
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(
        f"Merged catalog: {len(selected_ids)} updated, "
        f"{len(removed_ids)} removed, {len(catalog['plugins'])} total plugin(s)."
    )


if __name__ == "__main__":
    main()
