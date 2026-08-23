#!/usr/bin/env python3
from __future__ import annotations

import argparse
import plistlib
from pathlib import Path


BROKER_EXECUTABLE = "MacToolsCLIBroker"
LAUNCH_AGENT_NAME = "app.ggbond.MacTools.cli-broker.plist"


def fail(message: str) -> None:
    raise SystemExit(f"[artifact-validation] error: {message}")


def validate_directory(directory: Path, expected: set[str], description: str) -> None:
    if not directory.is_dir():
        fail(f"Missing {description} directory: {directory}")
    actual = {entry.name for entry in directory.iterdir()}
    if actual != expected:
        fail(
            f"Unexpected {description} entries: expected {sorted(expected)}, "
            f"found {sorted(actual)}"
        )
    for name in expected:
        entry = directory / name
        if not entry.is_file() or entry.is_symlink():
            fail(f"{description} entry must be a regular file: {name}")


def validate_layout(app: Path, host_executable: str, host_identifier: str) -> None:
    validate_directory(
        app / "Contents" / "MacOS",
        {host_executable, BROKER_EXECUTABLE},
        "Contents/MacOS",
    )
    launch_agents = app / "Contents" / "Library" / "LaunchAgents"
    validate_directory(launch_agents, {LAUNCH_AGENT_NAME}, "LaunchAgents")

    launch_agent_path = launch_agents / LAUNCH_AGENT_NAME
    try:
        with launch_agent_path.open("rb") as stream:
            actual = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"Invalid broker LaunchAgent plist: {error}")

    service = f"{host_identifier}.cli-broker"
    expected = {
        "Label": service,
        "BundleProgram": f"Contents/MacOS/{BROKER_EXECUTABLE}",
        "MachServices": {service: True},
        "ProcessType": "Interactive",
    }
    if actual != expected:
        fail("Broker LaunchAgent plist does not exactly match the authorized configuration")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--host-executable", required=True)
    parser.add_argument("--host-identifier", required=True)
    arguments = parser.parse_args()
    validate_layout(arguments.app, arguments.host_executable, arguments.host_identifier)


if __name__ == "__main__":
    main()
