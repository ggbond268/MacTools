#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$KEY" sign-plugin-catalog.sh \
    --input catalog.json --output catalog.signed.json

The private key must be an Ed25519 raw private key encoded as base64. Keep it in CI
secrets or a local env file; do not commit it. --private-key-base64 remains available
for compatibility, but the environment variable avoids forwarding the secret as a
child-process argument.
USAGE
}

INPUT=""
OUTPUT=""
PRIVATE_KEY_BASE64="${PLUGIN_CATALOG_PRIVATE_KEY_BASE64:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            INPUT="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT="${2:-}"
            shift 2
            ;;
        --private-key-base64)
            PRIVATE_KEY_BASE64="${2:-}"
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

if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$PRIVATE_KEY_BASE64" ]]; then
    usage >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$PRIVATE_KEY_BASE64" \
    xcrun swift "$SCRIPT_DIR/plugin-catalog-crypto.swift" sign \
        --input "$INPUT" \
        --output "$OUTPUT"
