#!/bin/zsh

set -euo pipefail

function usage() {
  cat <<'EOF'
Usage: scripts/package-cli.sh --binary <path> --output <zip>

Packages a built MacToolsCLI executable as a standalone archive whose root
contains one executable named `mactools`.
EOF
}

BINARY_PATH=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$BINARY_PATH" ]] || { echo "--binary is required" >&2; exit 1; }
[[ -n "$OUTPUT_PATH" ]] || { echo "--output is required" >&2; exit 1; }
[[ -x "$BINARY_PATH" ]] || { echo "CLI binary is not executable: $BINARY_PATH" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT_PATH")"
OUTPUT_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)/$(basename "$OUTPUT_PATH")"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mactools-cli-package.XXXXXX")"
trap '/bin/rm -rf "$STAGE_DIR"' EXIT

ditto "$BINARY_PATH" "$STAGE_DIR/mactools"
chmod 755 "$STAGE_DIR/mactools"
xattr -c "$STAGE_DIR/mactools"
rm -f "$OUTPUT_PATH"
/usr/bin/zip -X -j -q "$OUTPUT_PATH" "$STAGE_DIR/mactools"

[[ -s "$OUTPUT_PATH" ]] || { echo "CLI archive was not created: $OUTPUT_PATH" >&2; exit 1; }
