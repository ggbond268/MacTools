#!/usr/bin/env python3
"""Generate schema-3 plugin and website catalogs from plugin.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import stat
import unicodedata
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

from plugin_source_manifest import (
    ManifestValidationError,
    apply_nightly_package_overrides,
    expand_localized_references,
    load_known_plugin_ids,
    validate_and_project_manifest,
    validate_https_url,
    validate_nightly_build_number,
    validate_projected_manifest,
    validate_runtime_envelope,
)


SCHEMA3_MINIMUM_HOST_VERSION = "1.2.1"
MAX_PACKAGE_BYTES = 200 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 10_000
MAX_ARCHIVE_EXPANDED_BYTES = MAX_PACKAGE_BYTES
MAX_ARCHIVE_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ARCHIVE_SYMLINK_BYTES = 4096
SUPPORTED_ZIP_COMPRESSION = {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}


def version_tuple(value: str) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise SystemExit(f"Invalid minimum host version: {value}")
    return tuple(int(component) for component in value.split("."))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--package", type=Path, action="append", required=True)
    parser.add_argument("--base-url")
    parser.add_argument("--release-notes-url")
    parser.add_argument("--catalog-id", default="com.ggbond.mactools.plugins")
    parser.add_argument("--minimum-host-version")
    parser.add_argument("--nightly-build-number")
    parser.add_argument("--plugin-kit-version", type=int)
    parser.add_argument("--plugins-root", type=Path, default=Path("Plugins"))
    parser.add_argument("--website-output", type=Path)
    parser.add_argument("--generated-at")
    parser.add_argument("--allow-sparse-legacy", action="store_true")
    return parser.parse_args()


def directory_metrics(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    hidden_flag = getattr(stat, "UF_HIDDEN", 0)

    def is_hidden(candidate: Path) -> bool:
        relative = candidate.relative_to(path)
        current = path
        for part in relative.parts:
            current = current / part
            if part.startswith("."):
                return True
            if hidden_flag and current.lstat().st_flags & hidden_flag:
                return True
        return False

    files = sorted(
        candidate for candidate in path.rglob("*")
        if candidate.is_file()
        and not candidate.is_symlink()
        and not is_hidden(candidate)
    )
    for file_path in files:
        relative = file_path.relative_to(path).as_posix()
        data = file_path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
        size += len(data)
    return digest.hexdigest(), size


def file_metrics(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def _archive_parts(name: str, archive_path: Path) -> tuple[str, ...]:
    if not name or "\\" in name:
        raise SystemExit(f"{archive_path} contains an invalid archive path: {name!r}")
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"{archive_path} contains an unsafe archive path: {name}")
    parts = tuple(part for part in relative.parts if part not in {"", "."})
    if not parts:
        raise SystemExit(f"{archive_path} contains an empty archive path")
    return parts


def _archive_member_kind(info: zipfile.ZipInfo, archive_path: Path) -> str:
    if info.is_dir():
        return "directory"
    file_type = stat.S_IFMT((info.external_attr >> 16) & 0o177777)
    if file_type in {0, stat.S_IFREG}:
        return "file"
    if file_type == stat.S_IFLNK:
        return "symlink"
    raise SystemExit(f"{archive_path} contains unsupported archive member {info.filename}")


def _validate_archive_member_data(
    archive: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    archive_path: Path,
) -> None:
    if info.flag_bits & 0x1:
        raise SystemExit(f"{archive_path} contains an encrypted archive member: {info.filename}")
    if info.compress_type not in SUPPORTED_ZIP_COMPRESSION:
        raise SystemExit(
            f"{archive_path} contains an unsupported compression method: {info.filename}"
        )
    try:
        with archive.open(info) as member:
            while member.read(1024 * 1024):
                pass
    except (EOFError, NotImplementedError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise SystemExit(f"{archive_path} contains unreadable data: {info.filename}") from error


def _validate_archive_symlink(
    archive: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    parts: tuple[str, ...],
    package_root: str,
    archive_path: Path,
) -> None:
    if info.file_size <= 0 or info.file_size > MAX_ARCHIVE_SYMLINK_BYTES:
        raise SystemExit(f"{archive_path} contains an invalid symlink {info.filename}")
    try:
        target_text = archive.read(info).decode("utf-8")
    except (UnicodeDecodeError, RuntimeError, zipfile.BadZipFile) as error:
        raise SystemExit(f"{archive_path} contains an unreadable symlink {info.filename}") from error
    if not target_text or "\\" in target_text or "\0" in target_text:
        raise SystemExit(f"{archive_path} contains an invalid symlink {info.filename}")
    target = PurePosixPath(target_text)
    if target.is_absolute():
        raise SystemExit(f"{archive_path} contains an escaping symlink {info.filename}")
    resolved = list(parts[:-1])
    for component in target.parts:
        if component in {"", "."}:
            continue
        if component == "..":
            if not resolved:
                raise SystemExit(f"{archive_path} contains an escaping symlink {info.filename}")
            resolved.pop()
        else:
            resolved.append(component)
    if not resolved or resolved[0] != package_root:
        raise SystemExit(f"{archive_path} contains an escaping symlink {info.filename}")


def packaged_manifest(path: Path) -> tuple[dict, Path]:
    if path.suffix != ".zip":
        manifest_path = path / "plugin.json"
        if not manifest_path.is_file():
            raise SystemExit(f"Missing plugin.json: {path}")
        if manifest_path.stat().st_size <= 0 or manifest_path.stat().st_size > MAX_ARCHIVE_MANIFEST_BYTES:
            raise SystemExit(f"{path} contains an invalid package plugin.json size")
        return json.loads(manifest_path.read_text(encoding="utf-8")), manifest_path

    if path.stat().st_size > MAX_PACKAGE_BYTES:
        raise SystemExit(f"Package exceeds {MAX_PACKAGE_BYTES} bytes: {path}")
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile as error:
        raise SystemExit(f"Invalid ZIP package: {path}") from error
    with archive:
        infos = archive.infolist()
        if not infos or len(infos) > MAX_ARCHIVE_ENTRIES:
            raise SystemExit(
                f"{path} must contain 1...{MAX_ARCHIVE_ENTRIES} archive members"
            )
        expanded_size = sum(info.file_size for info in infos)
        if expanded_size > MAX_ARCHIVE_EXPANDED_BYTES:
            raise SystemExit(
                f"{path} expands beyond {MAX_ARCHIVE_EXPANDED_BYTES} bytes"
            )

        members: list[tuple[zipfile.ZipInfo, tuple[str, ...], str]] = []
        normalized_member_paths: set[tuple[str, ...]] = set()
        package_roots: set[str] = set()
        for info in infos:
            parts = _archive_parts(info.filename, path)
            normalized_parts = tuple(
                unicodedata.normalize("NFC", part).casefold()
                for part in parts
            )
            if normalized_parts in normalized_member_paths:
                raise SystemExit(f"{path} contains a duplicate archive path: {info.filename}")
            normalized_member_paths.add(normalized_parts)
            kind = _archive_member_kind(info, path)
            members.append((info, parts, kind))
            if parts[0].endswith(".mactoolsplugin"):
                package_roots.add(parts[0])
        if len(package_roots) != 1:
            raise SystemExit(f"{path} must contain exactly one .mactoolsplugin root")
        package_root = next(iter(package_roots))

        for info, parts, kind in members:
            if parts[0] not in {package_root, "__MACOSX"}:
                raise SystemExit(f"{path} contains unexpected top-level content: {parts[0]}")
            if kind == "symlink":
                if parts[0] != package_root:
                    raise SystemExit(f"{path} contains an unsupported metadata symlink")
                _validate_archive_symlink(archive, info, parts, package_root, path)
            if kind != "directory":
                _validate_archive_member_data(archive, info, path)

        manifest_members = [
            info
            for info, parts, kind in members
            if parts == (package_root, "plugin.json") and kind == "file"
        ]
        if len(manifest_members) != 1:
            raise SystemExit(f"{path} must contain exactly one package plugin.json")
        manifest_info = manifest_members[0]
        if manifest_info.file_size <= 0 or manifest_info.file_size > MAX_ARCHIVE_MANIFEST_BYTES:
            raise SystemExit(f"{path} contains an invalid package plugin.json size")
        try:
            manifest = json.loads(archive.read(manifest_info).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, RuntimeError, zipfile.BadZipFile) as error:
            raise SystemExit(f"{path} contains an invalid package plugin.json") from error
        return manifest, Path(f"{path}!/{package_root}/plugin.json")


def source_manifest_path(plugins_root: Path, plugin_id: str, packaged_path: Path) -> Path | None:
    matches = []
    if plugins_root.is_dir():
        candidates = list(plugins_root.glob("*/plugin.json"))
        if (plugins_root / "plugin.json").is_file():
            candidates.append(plugins_root / "plugin.json")
        for path in candidates:
            if path.resolve() == packaged_path.resolve():
                continue
            manifest = json.loads(path.read_text(encoding="utf-8"))
            if manifest.get("id") == plugin_id:
                matches.append(path)
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise SystemExit(f"Multiple source manifests match plugin ID {plugin_id}")
    return None


def _validated_https_url(value: str, field: str) -> None:
    try:
        validate_https_url(value, "catalog", field)
    except ManifestValidationError as error:
        raise SystemExit(str(error)) from error


def _source_package_projection(source_manifest: dict, source_path: Path) -> dict:
    projected = expand_localized_references(source_manifest, source_path)
    projected.pop("build", None)
    return projected


def _validate_source_package_parity(
    source_manifest: dict,
    source_path: Path,
    packaged: dict,
    packaged_path: Path,
    mode: str,
    nightly_build_number: str | None,
) -> None:
    expected = _source_package_projection(source_manifest, source_path)
    if mode == "debug" and "minHostVersion" in packaged:
        expected["minHostVersion"] = packaged["minHostVersion"]
    if nightly_build_number is not None:
        apply_nightly_package_overrides(expected, nightly_build_number)
    differing = sorted(
        key for key in set(expected) | set(packaged)
        if key not in expected
        or key not in packaged
        or expected[key] != packaged[key]
    )
    if differing:
        raise SystemExit(
            f"{packaged_path} does not match its source manifest: " + ", ".join(differing)
        )


def _validated_generated_at(value: str | None) -> str:
    generated_at = value or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", generated_at):
        raise SystemExit("--generated-at must use YYYY-MM-DDTHH:MM:SSZ")
    try:
        datetime.strptime(generated_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise SystemExit("--generated-at must use YYYY-MM-DDTHH:MM:SSZ") from error
    return generated_at


def validate_catalog(catalog: dict, mode: str) -> None:
    if not isinstance(catalog.get("catalogID"), str) or not catalog["catalogID"].strip():
        raise SystemExit("--catalog-id must not be blank")
    _validated_generated_at(catalog.get("generatedAt"))
    version_tuple(catalog.get("minimumHostVersion"))
    if type(catalog.get("pluginKitVersion")) is not int or catalog["pluginKitVersion"] < 1:
        raise SystemExit("Catalog pluginKitVersion must be a positive integer")
    seen_ids: set[str] = set()
    for entry in catalog.get("plugins", []):
        plugin_id = entry["id"]
        if plugin_id in seen_ids:
            raise SystemExit(f"Catalog contains duplicate plugin ID: {plugin_id}")
        seen_ids.add(plugin_id)
        package = entry["package"]
        if (
            type(package.get("size")) is not int
            or package["size"] <= 0
            or package["size"] > MAX_PACKAGE_BYTES
        ):
            raise SystemExit(f"{plugin_id}: package size is outside the supported range")
        if not isinstance(package.get("sha256"), str) or not re.fullmatch(
            r"[a-fA-F0-9]{64}", package["sha256"]
        ):
            raise SystemExit(f"{plugin_id}: package checksum must be SHA-256")
        package_url = package.get("url")
        parsed = urlparse(package_url) if isinstance(package_url, str) else None
        if mode == "debug" and parsed is not None and parsed.scheme == "file":
            pass
        elif isinstance(package_url, str):
            _validated_https_url(package_url, f"plugins.{plugin_id}.package.url")
        else:
            raise SystemExit(f"{plugin_id}: package URL is invalid")
        release_notes_url = entry.get("releaseNotesURL")
        if release_notes_url is not None:
            _validated_https_url(release_notes_url, f"plugins.{plugin_id}.releaseNotesURL")


def main() -> None:
    args = parse_args()
    if args.mode == "release" and not args.base_url:
        raise SystemExit("--base-url is required in release mode")
    if args.mode == "release" and args.allow_sparse_legacy:
        raise SystemExit("--allow-sparse-legacy is available only for local debug catalogs")
    if args.nightly_build_number is not None:
        if args.mode != "release":
            raise SystemExit("--nightly-build-number is available only in release mode")
        try:
            validate_nightly_build_number(args.nightly_build_number)
        except ManifestValidationError as error:
            raise SystemExit(str(error)) from error
    if not args.catalog_id.strip():
        raise SystemExit("--catalog-id must not be blank")
    generated_at = _validated_generated_at(args.generated_at)
    if args.base_url is not None:
        _validated_https_url(args.base_url, "--base-url")
        parsed_base_url = urlparse(args.base_url)
        if parsed_base_url.query or parsed_base_url.fragment:
            raise SystemExit("--base-url must not contain a query or fragment")
    if args.release_notes_url is not None:
        _validated_https_url(args.release_notes_url, "--release-notes-url")
    minimum_host_version = args.minimum_host_version or (
        SCHEMA3_MINIMUM_HOST_VERSION if args.mode == "release" else "0.1.0"
    )
    if args.mode == "release" and version_tuple(minimum_host_version) < version_tuple(
        SCHEMA3_MINIMUM_HOST_VERSION
    ):
        raise SystemExit(
            "Schema 3 release catalogs require MacTools "
            f"{SCHEMA3_MINIMUM_HOST_VERSION} or later."
        )
    try:
        known_plugin_ids = load_known_plugin_ids(args.plugins_root) if args.plugins_root.is_dir() else set()
    except ManifestValidationError as error:
        raise SystemExit(str(error)) from error
    entries = []
    website_plugins = []
    plugin_kit_versions = set()
    seen_package_ids: dict[str, Path] = {}
    for raw_path in args.package:
        package_path = raw_path.expanduser().resolve()
        if not package_path.exists():
            raise SystemExit(f"Package not found: {package_path}")
        packaged, packaged_manifest_path = packaged_manifest(package_path)
        try:
            plugin_id = validate_runtime_envelope(
                packaged,
                packaged_manifest_path,
                allow_sparse_legacy=args.allow_sparse_legacy,
            )
        except ManifestValidationError as error:
            raise SystemExit(str(error)) from error
        previous_package = seen_package_ids.get(plugin_id)
        if previous_package is not None:
            raise SystemExit(
                f"Duplicate package plugin ID {plugin_id}: {previous_package} and {package_path}"
            )
        seen_package_ids[plugin_id] = package_path

        source_path = source_manifest_path(args.plugins_root, plugin_id, packaged_manifest_path)
        try:
            if source_path is None:
                projected = validate_projected_manifest(
                    packaged,
                    packaged_manifest_path,
                    known_plugin_ids or {plugin_id},
                    allow_sparse_legacy=args.allow_sparse_legacy,
                    validate_plugin_references=False,
                )
                assets = []
            else:
                source_manifest = json.loads(source_path.read_text(encoding="utf-8"))
                projected, assets = validate_and_project_manifest(
                    source_manifest,
                    source_path,
                    known_plugin_ids or {plugin_id},
                    allow_sparse_legacy=args.allow_sparse_legacy,
                )
                validate_projected_manifest(
                    packaged,
                    packaged_manifest_path,
                    known_plugin_ids or {plugin_id},
                    allow_sparse_legacy=args.allow_sparse_legacy,
                )
                if args.nightly_build_number is not None:
                    apply_nightly_package_overrides(
                        projected,
                        args.nightly_build_number,
                    )
                _validate_source_package_parity(
                    source_manifest,
                    source_path,
                    packaged,
                    packaged_manifest_path,
                    args.mode,
                    args.nightly_build_number,
                )
        except ManifestValidationError as error:
            raise SystemExit(str(error)) from error

        if (
            source_path is None
            and projected.get("presentation", {}).get("screenshots")
        ):
            raise SystemExit(
                f"{packaged_manifest_path}: catalog screenshots require a matching source manifest"
            )

        manifest_plugin_kit_version = int(packaged["pluginKitVersion"])
        plugin_kit_versions.add(manifest_plugin_kit_version)
        if args.plugin_kit_version is not None and manifest_plugin_kit_version != args.plugin_kit_version:
            raise SystemExit(
                f"{packaged_manifest_path} uses pluginKitVersion {manifest_plugin_kit_version}, "
                f"but --plugin-kit-version is {args.plugin_kit_version}"
            )
        digest, size = directory_metrics(package_path) if package_path.is_dir() else file_metrics(package_path)
        if size <= 0 or size > MAX_PACKAGE_BYTES:
            raise SystemExit(
                f"{package_path}: package size must be 1...{MAX_PACKAGE_BYTES} bytes"
            )
        package_url = (
            package_path.as_uri()
            if args.mode == "debug"
            else args.base_url.rstrip("/") + "/" + package_path.name
        )
        entry = {
            "id": plugin_id,
            "displayName": projected.get("displayName", plugin_id),
            "summary": projected.get("summary", projected.get("displayName", plugin_id)),
            "localizedMetadata": projected.get("localizedMetadata"),
            "version": packaged["version"],
            "minimumHostVersion": packaged.get("minHostVersion", minimum_host_version),
            "pluginKitVersion": manifest_plugin_kit_version,
            "capabilities": packaged.get("capabilities", {
                "primaryPanel": False, "componentPanel": False, "settings": "none"
            }),
            "permissions": packaged.get("permissions", []),
            "package": {"url": package_url, "sha256": digest, "size": size},
            "releaseNotesURL": projected.get("releaseNotesURL") or args.release_notes_url,
            "category": projected.get("category"),
            "releaseChannel": projected.get("releaseChannel"),
        }
        for section in (
            "presentation", "discovery", "requirements", "privacy",
            "actions", "setup", "relationships",
        ):
            if section in projected:
                entry[section] = projected[section]
        entries.append(entry)
        website_entry = {
            key: value for key, value in entry.items()
            if key not in {"package", "releaseChannel"}
        }
        website_plugins.append((website_entry, assets))

    if args.plugin_kit_version is None:
        if len(plugin_kit_versions) != 1:
            raise SystemExit(
                "Packages must use one pluginKitVersion: "
                + ", ".join(map(str, sorted(plugin_kit_versions)))
            )
        catalog_plugin_kit_version = next(iter(plugin_kit_versions))
    else:
        catalog_plugin_kit_version = args.plugin_kit_version
    catalog = {
        "schemaVersion": 3,
        "catalogID": args.catalog_id,
        "generatedAt": generated_at,
        "minimumHostVersion": minimum_host_version,
        "pluginKitVersion": catalog_plugin_kit_version,
        "plugins": sorted(entries, key=lambda entry: entry["id"]),
        "revoked": [],
    }
    validate_catalog(catalog, args.mode)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if args.website_output is not None:
        assets_root = args.website_output.parent / "assets"
        website_values = []
        for website_entry, assets in sorted(website_plugins, key=lambda value: value[0]["id"]):
            for asset in assets:
                destination_name = f"{asset.catalog['sha256']}{asset.source.suffix.lower()}"
                assets_root.mkdir(parents=True, exist_ok=True)
                shutil.copy2(asset.source, assets_root / destination_name)
                for screenshot in website_entry.get("presentation", {}).get("screenshots", []):
                    if screenshot["id"] == asset.catalog["id"]:
                        screenshot["path"] = f"assets/{destination_name}"
            website_values.append(website_entry)
        website = {"schemaVersion": 1, "plugins": website_values}
        args.website_output.parent.mkdir(parents=True, exist_ok=True)
        args.website_output.write_text(
            json.dumps(website, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
