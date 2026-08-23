#!/bin/zsh

set -euo pipefail

ARTIFACT=""
OUTPUT=""

function fail() {
  printf '[checksum] error: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -f "$ARTIFACT" ]] || fail "Artifact not found: $ARTIFACT"
[[ -n "$OUTPUT" ]] || fail "Output path is required."

ARTIFACT="${ARTIFACT:A}"
OUTPUT="${OUTPUT:A}"
(
  cd "${ARTIFACT:h}"
  /usr/bin/shasum -a 256 "${ARTIFACT:t}"
) > "$OUTPUT"
