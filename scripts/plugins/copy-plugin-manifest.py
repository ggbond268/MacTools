#!/usr/bin/env python3
"""Copy a plugin manifest, normalizing Debug compatibility to the local host."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
from typing import Optional

from plugin_source_manifest import expand_localized_references, validate_runtime_envelope


MARKETING_VERSION_PATTERN = re.compile(
    r"^\s*MARKETING_VERSION\s*=\s*(\S+)\s*$",
    re.MULTILINE,
)
PLUGIN_VERSION_PATTERN = re.compile(r"^([0-9]+)(?:\.[0-9]+){0,2}$")
NIGHTLY_BUILD_PATTERN = re.compile(r"^([0-9]+)\.([0-9]+)$")


def development_host_version(config_path: pathlib.Path) -> str:
    match = MARKETING_VERSION_PATTERN.search(config_path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"Unable to determine MARKETING_VERSION from {config_path}")
    return match.group(1)


def copy_manifest(
    source: pathlib.Path,
    destination: pathlib.Path,
    configuration: str,
    app_version_config: pathlib.Path,
    nightly_build_number: Optional[str] = None,
    allow_sparse_legacy: bool = False,
) -> None:
    if nightly_build_number is not None and configuration != "Nightly":
        raise ValueError("Nightly build number is only valid for the Nightly configuration")

    manifest = json.loads(source.read_text(encoding="utf-8"))
    had_build_metadata = "build" in manifest
    manifest.pop("build", None)
    expanded_manifest = expand_localized_references(manifest, source)
    had_localization_references = expanded_manifest != manifest
    manifest = expanded_manifest
    validate_runtime_envelope(
        manifest,
        source,
        allow_sparse_legacy=allow_sparse_legacy,
    )

    if configuration == "Nightly" and manifest["id"] in {"fan-control", "battery-charge-limit"}:
        helper_path = f"/Library/PrivilegedHelperTools/cc.ggbond.mactools.{manifest['id']}.smc-helper"
        for step in manifest.get("setup", {}).get("steps", []):
            if step.get("id") == "install-privileged-helper":
                step["description"] = {
                    locale: description.replace(helper_path, helper_path + ".nightly")
                    for locale, description in step["description"].items()
                }

    if nightly_build_number is not None:
        source_version = str(manifest["version"])
        source_match = PLUGIN_VERSION_PATTERN.fullmatch(source_version)
        build_match = NIGHTLY_BUILD_PATTERN.fullmatch(nightly_build_number)
        if source_match is None:
            raise ValueError("source plugin version must contain one to three numeric components")
        if build_match is None:
            raise ValueError("Nightly build number must use numeric run.attempt components")
        manifest["version"] = (
            f"{source_match.group(1)}.{build_match.group(1)}.{build_match.group(2)}"
        )

    if (
        configuration not in {"Debug", "Nightly"}
        and nightly_build_number is None
        and not had_build_metadata
        and not had_localization_references
    ):
        shutil.copy2(source, destination)
        return

    if configuration == "Debug":
        manifest["minHostVersion"] = development_host_version(app_version_config)
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    copy_parser = subparsers.add_parser("copy")
    copy_parser.add_argument("--source", type=pathlib.Path, required=True)
    copy_parser.add_argument("--destination", type=pathlib.Path, required=True)
    copy_parser.add_argument("--configuration", required=True)
    copy_parser.add_argument("--app-version-config", type=pathlib.Path, required=True)
    copy_parser.add_argument("--nightly-build-number")
    copy_parser.add_argument("--allow-sparse-legacy", action="store_true")

    version_parser = subparsers.add_parser("host-version")
    version_parser.add_argument("--app-version-config", type=pathlib.Path, required=True)

    args = parser.parse_args()
    if args.command == "host-version":
        print(development_host_version(args.app_version_config))
        return

    copy_manifest(
        source=args.source,
        destination=args.destination,
        configuration=args.configuration,
        app_version_config=args.app_version_config,
        nightly_build_number=args.nightly_build_number,
        allow_sparse_legacy=args.allow_sparse_legacy,
    )


if __name__ == "__main__":
    main()
