#!/usr/bin/env python3
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path


EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}


def fail(message: str) -> None:
    raise SystemExit(f"[artifact-validation] error: {message}")


def validate_architectures(value: str, role: str) -> None:
    architectures = value.split()
    if len(architectures) != 2 or set(architectures) != EXPECTED_ARCHITECTURES:
        fail(
            f"{role} must contain exactly arm64 and x86_64 slices; "
            f"found: {value or 'none'}"
        )


def extract_embedded_plist(value: str) -> bytes:
    output = bytearray()
    for line in value.splitlines():
        fields = line.split()
        if fields and re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            for word in fields[1:]:
                if not re.fullmatch(r"(?:[0-9a-fA-F]{2}){1,4}", word):
                    fail(f"Invalid __info_plist word: {word}")
                output.extend(bytes.fromhex(word)[::-1])
    result = bytes(output).rstrip(b"\0")
    if not result:
        fail("Mach-O __info_plist section is empty")
    return result


def validate_info(
    plist_path: Path,
    expected_identifier: str,
    expected_version: str,
    expected_build: str,
    role: str,
) -> None:
    try:
        with plist_path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"Missing or invalid embedded Info.plist for {role}: {error}")
    actual = (
        value.get("CFBundleIdentifier"),
        value.get("CFBundleShortVersionString"),
        value.get("CFBundleVersion"),
    )
    expected = (expected_identifier, expected_version, expected_build)
    if actual != expected:
        fail(f"Embedded identity/version mismatch for {role}: expected {expected}, found {actual}")


def signing_value(details: str, key: str) -> str | None:
    prefix = f"{key}="
    return next(
        (line[len(prefix):] for line in details.splitlines() if line.startswith(prefix)),
        None,
    )


def validate_signing_details(
    details: str,
    expected_identifier: str,
    expected_team: str,
    role: str,
) -> None:
    identifier = signing_value(details, "Identifier")
    team = signing_value(details, "TeamIdentifier")
    if identifier != expected_identifier:
        fail(f"Signing identifier mismatch for {role}")
    if not expected_team or team != expected_team:
        fail(f"Team Identifier mismatch for {role}")
    if not any("flags=" in line and "(runtime)" in line for line in details.splitlines()):
        fail(f"Hardened runtime is missing for {role}")


def validate_command_status(status: int, operation: str) -> None:
    if status != 0:
        fail(f"{operation} failed with status {status}")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    architectures = subparsers.add_parser("architectures")
    architectures.add_argument("--value", required=True)
    architectures.add_argument("--role", required=True)

    subparsers.add_parser("extract-info")

    info = subparsers.add_parser("info")
    info.add_argument("--plist", type=Path, required=True)
    info.add_argument("--identifier", required=True)
    info.add_argument("--version", required=True)
    info.add_argument("--build", required=True)
    info.add_argument("--role", required=True)

    signing = subparsers.add_parser("signing")
    signing.add_argument("--details", type=Path, required=True)
    signing.add_argument("--identifier", required=True)
    signing.add_argument("--team", required=True)
    signing.add_argument("--role", required=True)

    status = subparsers.add_parser("status")
    status.add_argument("--value", type=int, required=True)
    status.add_argument("--operation", required=True)

    arguments = parser.parse_args()
    if arguments.command == "architectures":
        validate_architectures(arguments.value, arguments.role)
    elif arguments.command == "extract-info":
        sys.stdout.buffer.write(extract_embedded_plist(sys.stdin.read()))
    elif arguments.command == "info":
        validate_info(
            arguments.plist,
            arguments.identifier,
            arguments.version,
            arguments.build,
            arguments.role,
        )
    elif arguments.command == "signing":
        validate_signing_details(
            arguments.details.read_text(),
            arguments.identifier,
            arguments.team,
            arguments.role,
        )
    elif arguments.command == "status":
        validate_command_status(arguments.value, arguments.operation)


if __name__ == "__main__":
    main()
