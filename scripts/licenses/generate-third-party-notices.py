#!/usr/bin/env python3
"""Generate product-specific third-party notices from the central manifest."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any


SUPPORTED_RELATIONSHIPS = frozenset(
    {"dependency", "bundled", "adapted", "asset", "build-only"}
)
PRODUCT_PATTERN = re.compile(r"(?:app|plugin:[A-Za-z0-9][A-Za-z0-9._-]{1,126}[A-Za-z0-9])\Z")
REVISION_PATTERN = re.compile(r"[0-9a-f]{40}\Z")


class NoticeManifestError(ValueError):
    """Raised when the notice manifest is incomplete or unsafe."""


def _non_empty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise NoticeManifestError(f"{field} must be a non-empty string")
    return value.strip()


def _string_list(value: Any, field: str) -> list[str]:
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(item, str) and item.strip() for item in value)
    ):
        raise NoticeManifestError(f"{field} must be a non-empty string array")
    normalized = [item.strip() for item in value]
    if len(normalized) != len(set(normalized)):
        raise NoticeManifestError(f"{field} must not contain duplicates")
    return normalized


def _resolve_repository_path(repo_root: Path, raw_path: str, field: str) -> Path:
    relative = Path(raw_path)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise NoticeManifestError(f"{field} must be a normalized repository-relative path")

    resolved = (repo_root / relative).resolve()
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise NoticeManifestError(f"{field} resolves outside the repository") from error

    if not resolved.exists():
        raise NoticeManifestError(f"{field} does not exist: {raw_path}")
    return resolved


def load_components(manifest_path: Path, repo_root: Path) -> list[dict[str, Any]]:
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NoticeManifestError(f"unable to read {manifest_path}: {error}") from error

    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise NoticeManifestError("manifest schemaVersion must be 1")

    raw_components = document.get("components")
    if not isinstance(raw_components, list):
        raise NoticeManifestError("manifest components must be an array")

    components: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    for index, raw_component in enumerate(raw_components):
        field = f"components[{index}]"
        if not isinstance(raw_component, dict):
            raise NoticeManifestError(f"{field} must be an object")

        component_id = _non_empty_string(raw_component.get("id"), f"{field}.id")
        if component_id in seen_ids:
            raise NoticeManifestError(f"duplicate component id: {component_id}")
        seen_ids.add(component_id)

        name = _non_empty_string(raw_component.get("name"), f"{field}.name")
        repository = _non_empty_string(
            raw_component.get("repository"), f"{field}.repository"
        )
        if not repository.startswith("https://"):
            raise NoticeManifestError(f"{field}.repository must use https")

        revision = _non_empty_string(raw_component.get("revision"), f"{field}.revision")
        if REVISION_PATTERN.fullmatch(revision) is None:
            raise NoticeManifestError(f"{field}.revision must be a full Git commit SHA")

        license_id = _non_empty_string(raw_component.get("license"), f"{field}.license")
        compatibility = _non_empty_string(
            raw_component.get("gpl3Compatibility"),
            f"{field}.gpl3Compatibility",
        )
        relationship = _non_empty_string(
            raw_component.get("relationship"), f"{field}.relationship"
        )
        if relationship not in SUPPORTED_RELATIONSHIPS:
            raise NoticeManifestError(
                f"{field}.relationship is unsupported: {relationship}"
            )
        expected_compatibility = (
            "not-applicable" if relationship == "build-only" else "compatible"
        )
        if compatibility != expected_compatibility:
            raise NoticeManifestError(
                f"{field}.gpl3Compatibility must be {expected_compatibility!r} "
                f"for relationship {relationship!r}"
            )

        products = _string_list(raw_component.get("products"), f"{field}.products")
        for product in products:
            if PRODUCT_PATTERN.fullmatch(product) is None:
                raise NoticeManifestError(f"{field}.products contains invalid value: {product}")

        paths = _string_list(raw_component.get("paths"), f"{field}.paths")
        for path_index, source_path in enumerate(paths):
            _resolve_repository_path(
                repo_root,
                source_path,
                f"{field}.paths[{path_index}]",
            )

        license_file_value = _non_empty_string(
            raw_component.get("licenseFile"), f"{field}.licenseFile"
        )
        license_file = _resolve_repository_path(
            repo_root,
            license_file_value,
            f"{field}.licenseFile",
        )
        if not license_file.is_file():
            raise NoticeManifestError(f"{field}.licenseFile must be a regular file")

        include_license_text = raw_component.get("includeLicenseText", True)
        if not isinstance(include_license_text, bool):
            raise NoticeManifestError(f"{field}.includeLicenseText must be a boolean")

        components.append(
            {
                "id": component_id,
                "name": name,
                "repository": repository,
                "revision": revision,
                "license": license_id,
                "gpl3Compatibility": compatibility,
                "relationship": relationship,
                "products": products,
                "paths": paths,
                "licenseFile": license_file,
                "includeLicenseText": include_license_text,
            }
        )

    return components


def render_notices(components: list[dict[str, Any]], product: str) -> str | None:
    selected = [component for component in components if product in component["products"]]
    if not selected:
        return None

    lines = [
        "MACTOOLS THIRD-PARTY NOTICES",
        "",
        "This file is generated from Sources/Resources/ThirdPartyNotices/manifest.json.",
        "Third-party material remains subject to the license identified in each entry.",
    ]

    for component in selected:
        lines.extend(
            [
                "",
                "=" * 79,
                component["name"],
                f"Upstream: {component['repository']}",
                f"Revision: {component['revision']}",
                f"Relationship: {component['relationship']}",
                f"License: {component['license']}",
                f"MacTools paths: {', '.join(component['paths'])}",
                "-" * 79,
            ]
        )
        if component["includeLicenseText"]:
            license_text = component["licenseFile"].read_text(encoding="utf-8").rstrip()
            lines.extend([license_text, ""])
        else:
            lines.extend(
                [
                    "The complete license text is provided in LICENSE alongside this notice.",
                    "",
                ]
            )

    return "\n".join(lines).rstrip() + "\n"


def write_output(output: Path, content: str | None) -> None:
    if content is None:
        if output.exists():
            output.unlink()
        return

    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=f".{output.name}.",
        dir=output.parent,
        text=True,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.write(content)
        os.replace(temporary_path, output)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--product", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repo_root = arguments.repo_root.resolve()
    if not repo_root.is_dir():
        raise NoticeManifestError(f"repository root does not exist: {repo_root}")
    if PRODUCT_PATTERN.fullmatch(arguments.product) is None:
        raise NoticeManifestError(f"invalid product selector: {arguments.product}")

    components = load_components(arguments.manifest.resolve(), repo_root)
    write_output(arguments.output, render_notices(components, arguments.product))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except NoticeManifestError as error:
        raise SystemExit(f"third-party notice error: {error}")
