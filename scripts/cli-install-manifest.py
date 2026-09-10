#!/usr/bin/env python3
"""Bind a separate CLI archive to an app before its outer Developer ID signature.

Works with GitHub immutable release URLs and personal /releases/<build> channels.
The published JSON is informational; installers trust only the copy sealed in the app.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import urllib.parse
import zipfile


def make_manifest(archive, app, source_release, source_commit, team, protocol_source):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    identifier = info["CFBundleIdentifier"]
    if (info.get("MTReleaseChannel") != "nightly"
            or not identifier.endswith(".mactools.nightly")
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", version)
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", build)
            or not re.fullmatch(r"[a-f0-9]{40}", source_commit)
            or not re.fullmatch(r"[A-Z0-9]{10}", team)):
        raise ValueError("Invalid Nightly app identity or source metadata")
    url = urllib.parse.urlsplit(source_release)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.port or url.query or url.fragment or "%" in source_release
            or ".." in url.path.split("/")
            or not (url.path == f"/releases/{build}" or url.path.endswith(
                "/releases/download/nightly-" + build.replace(".", "-")))):
        raise ValueError("CLI source release must be an immutable HTTPS release directory")
    expected = f"mactools-cli-{version}-{build}-macos-arm64.zip"
    data = archive.read_bytes()
    if archive.name != expected or not 0 < len(data) <= 64 * 1024 * 1024:
        raise ValueError("Invalid CLI archive name or size")
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) != 2 or {e.filename for e in entries} != {"mactools", "LICENSE"}:
            raise ValueError("Unexpected CLI archive entries")
        for entry in entries:
            mode = 0o100755 if entry.filename == "mactools" else 0o100644
            maximum = 64 * 1024 * 1024 if entry.filename == "mactools" else 65536
            if (entry.external_attr >> 16 != mode or entry.flag_bits or entry.extra
                    or not 0 < entry.file_size <= maximum):
                raise ValueError("Invalid CLI archive entry")
        if zipped.read("mactools")[:8] != bytes.fromhex("cffaedfe0c000001"):
            raise ValueError("CLI must be a thin arm64 Mach-O executable")
    protocol = protocol_source.read_text()
    minimum = int(re.search(r"public static let minimum = (\d+)", protocol)[1])
    maximum = int(re.search(r"public static let current = (\d+)", protocol)[1])
    return dict(schema=1, channel="nightly", appVersion=version, appBuild=build,
                cliVersion=version, cliBuild=build, sourceCommit=source_commit,
                sourceRelease=source_release, assetURL=source_release + "/" + expected,
                sha256=hashlib.sha256(data).hexdigest(), size=len(data), architecture="arm64",
                signingIdentifier=identifier + ".cli", teamIdentifier=team,
                protocolMinimum=minimum, protocolMaximum=maximum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--source-release", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--protocol-source", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1] / "Sources/MacToolsCLIProtocol/CLIProtocolModels.swift")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest = make_manifest(args.archive, args.app, args.source_release,
                             args.source_commit, args.team, args.protocol_source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    resource = args.app / "Contents/Resources/cli-install.json"
    resource.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.output, resource)


if __name__ == "__main__":
    main()
