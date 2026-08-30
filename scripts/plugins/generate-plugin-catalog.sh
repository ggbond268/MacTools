#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PYTHON_BIN="${PYTHON3:-/usr/bin/python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/generate-plugin-catalog.py" "$@"
