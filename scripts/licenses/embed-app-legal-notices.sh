#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  embed-app-legal-notices.sh --app-bundle /path/to/MacTools.app

Copies the repository GPL license and a generated application-specific
third-party notice file into the built app bundle.
USAGE
}

APP_BUNDLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-bundle)
            APP_BUNDLE="${2:-}"
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

if [[ -z "$APP_BUNDLE" ]]; then
    usage >&2
    exit 1
fi

[[ -d "$APP_BUNDLE" ]] || {
    echo "App bundle not found: $APP_BUNDLE" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LICENSE_PATH="$REPO_ROOT/LICENSE"
NOTICE_MANIFEST="$REPO_ROOT/Sources/Resources/ThirdPartyNotices/manifest.json"
NOTICE_GENERATOR="$REPO_ROOT/scripts/licenses/generate-third-party-notices.py"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

[[ -f "$LICENSE_PATH" ]] || {
    echo "Repository license not found: $LICENSE_PATH" >&2
    exit 1
}

mkdir -p "$RESOURCES_DIR"
ditto "$LICENSE_PATH" "$RESOURCES_DIR/LICENSE"
"${PYTHON3:-python3}" "$NOTICE_GENERATOR" \
    --manifest "$NOTICE_MANIFEST" \
    --repo-root "$REPO_ROOT" \
    --product app \
    --output "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
