#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
FIXTURE_DIR="$REPO_ROOT/scripts/fixtures/plugin-kit-v6"
PRODUCTS_DIR="${1:-$REPO_ROOT/build/DerivedData/Build/Products/Debug}"
FRAMEWORK_PATH="$PRODUCTS_DIR/MacToolsPluginKit.framework"

[[ -d "$FRAMEWORK_PATH" ]] || {
    print -u2 -r -- "error: MacToolsPluginKit framework is missing at $FRAMEWORK_PATH"
    exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mactools-plugin-kit-v6.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

TARGET="$(uname -m)-apple-macos14.0"
MODULE_PATH="$TEMP_DIR/MacToolsPluginKit.swiftmodule"
CLIENT_PATH="$TEMP_DIR/plugin-kit-v6-client"

xcrun swiftc \
    -parse-as-library \
    -emit-module \
    -module-name MacToolsPluginKit \
    -target "$TARGET" \
    "$FIXTURE_DIR/MacToolsPluginKit.swift" \
    -emit-module-path "$MODULE_PATH"

xcrun swiftc \
    -parse-as-library \
    -target "$TARGET" \
    -I "$TEMP_DIR" \
    -F "$PRODUCTS_DIR" \
    "$FIXTURE_DIR/Client.swift" \
    -framework MacToolsPluginKit \
    -o "$CLIENT_PATH"

DYLD_FRAMEWORK_PATH="$PRODUCTS_DIR" "$CLIENT_PATH"
print -r -- "PluginKit v6 binary compatibility client passed."
