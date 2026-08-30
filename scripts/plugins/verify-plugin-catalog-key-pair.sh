#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$KEY" verify-plugin-catalog-key-pair.sh \
    --public-key-base64 "$PUBLIC_KEY"

Verifies that the Ed25519 private key supplied through the environment matches the
public key embedded in the app. The key material is never printed.
USAGE
}

PUBLIC_KEY_BASE64=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-key-base64)
            PUBLIC_KEY_BASE64="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PUBLIC_KEY_BASE64" || -z "${PLUGIN_CATALOG_PRIVATE_KEY_BASE64:-}" ]]; then
    usage >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
xcrun swift "$SCRIPT_DIR/plugin-catalog-crypto.swift" verify-key-pair \
    --public-key-base64 "$PUBLIC_KEY_BASE64"
