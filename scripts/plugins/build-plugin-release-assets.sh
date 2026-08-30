#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  build-plugin-release-assets.sh --base-url URL --catalog-output dist/catalog.json --sign-identity "Developer ID Application: ..." [--plugin ID]...

Builds selected plugin packages, signs their bundles, zips them as release assets,
generates a release catalog for those assets, and optionally writes a signed catalog.
Without --plugin it builds all discovered plugins. --plugin can be repeated or
passed as a comma-separated list. --nightly-build-number derives valid,
monotonic source-major.run.attempt versions without changing source manifests.
USAGE
}

SOURCE_DIR="Plugins"
BUILD_DIR="build/PluginRelease/Build"
DIST_DIR="build/PluginRelease"
ASSETS_DIR=""
BASE_URL=""
CATALOG_OUTPUT=""
SIGNED_CATALOG_OUTPUT=""
CATALOG_PRIVATE_KEY_BASE64="${PLUGIN_CATALOG_PRIVATE_KEY_BASE64:-}"
SIGN_IDENTITY="${PLUGIN_CODE_SIGN_IDENTITY:-}"
CONFIGURATION="Release"
DESTINATION=""
XCODEBUILD_COMMAND="${XCODEBUILD:-}"
MINIMUM_HOST_VERSION=""
RELEASE_NOTES_URL=""
NIGHTLY_BUILD_NUMBER=""
PRODUCTS_DIR=""
PLUGIN_FILTERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            SOURCE_DIR="${2:-}"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="${2:-}"
            shift 2
            ;;
        --dist-dir)
            DIST_DIR="${2:-}"
            shift 2
            ;;
        --assets-dir)
            ASSETS_DIR="${2:-}"
            shift 2
            ;;
        --base-url)
            BASE_URL="${2:-}"
            shift 2
            ;;
        --catalog-output)
            CATALOG_OUTPUT="${2:-}"
            shift 2
            ;;
        --signed-catalog-output)
            SIGNED_CATALOG_OUTPUT="${2:-}"
            shift 2
            ;;
        --catalog-private-key-base64)
            CATALOG_PRIVATE_KEY_BASE64="${2:-}"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="${2:-}"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --destination)
            DESTINATION="${2:-}"
            shift 2
            ;;
        --xcodebuild)
            XCODEBUILD_COMMAND="${2:-}"
            shift 2
            ;;
        --minimum-host-version)
            MINIMUM_HOST_VERSION="${2:-}"
            shift 2
            ;;
        --release-notes-url)
            RELEASE_NOTES_URL="${2:-}"
            shift 2
            ;;
        --nightly-build-number)
            NIGHTLY_BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --products-dir)
            PRODUCTS_DIR="${2:-}"
            shift 2
            ;;
        --plugin)
            IFS=',' read -r -a raw_plugin_filters <<< "${2:-}"
            for raw_plugin_filter in "${raw_plugin_filters[@]}"; do
                raw_plugin_filter="${raw_plugin_filter#"${raw_plugin_filter%%[![:space:]]*}"}"
                raw_plugin_filter="${raw_plugin_filter%"${raw_plugin_filter##*[![:space:]]}"}"
                [[ -n "$raw_plugin_filter" ]] && PLUGIN_FILTERS+=("$raw_plugin_filter")
            done
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

if [[ "$CONFIGURATION" == "Nightly" && -z "$NIGHTLY_BUILD_NUMBER" ]]; then
    echo "--nightly-build-number is required for Nightly plugin release assets." >&2
    exit 1
fi
if [[ "$CONFIGURATION" != "Nightly" && -n "$NIGHTLY_BUILD_NUMBER" ]]; then
    echo "--nightly-build-number is only valid with --configuration Nightly." >&2
    exit 1
fi

if [[ -z "$BASE_URL" || -z "$CATALOG_OUTPUT" ]]; then
    usage >&2
    exit 1
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "--sign-identity or PLUGIN_CODE_SIGN_IDENTITY is required for plugin release assets." >&2
    exit 1
fi

if [[ -n "$SIGNED_CATALOG_OUTPUT" && -z "$CATALOG_PRIVATE_KEY_BASE64" ]]; then
    echo "--catalog-private-key-base64 or PLUGIN_CATALOG_PRIVATE_KEY_BASE64 is required when signing the catalog." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ASSETS_DIR="${ASSETS_DIR:-$DIST_DIR/Assets}"
rm -rf "$ASSETS_DIR"
mkdir -p "$ASSETS_DIR" "$(dirname "$CATALOG_OUTPUT")"

build_args=(
    --source-dir "$SOURCE_DIR"
    --output-dir "$BUILD_DIR"
    --configuration "$CONFIGURATION"
    --sign-identity "$SIGN_IDENTITY"
    --unsigned-build
    --skip-catalog
)
if [[ -n "$DESTINATION" ]]; then
    build_args+=(--destination "$DESTINATION")
fi
if [[ -n "$XCODEBUILD_COMMAND" ]]; then
    build_args+=(--xcodebuild "$XCODEBUILD_COMMAND")
fi
if [[ -n "$NIGHTLY_BUILD_NUMBER" ]]; then
    build_args+=(--nightly-build-number "$NIGHTLY_BUILD_NUMBER")
fi
if [[ -n "$PRODUCTS_DIR" ]]; then
    build_args+=(--products-dir "$PRODUCTS_DIR")
fi
for plugin_filter in "${PLUGIN_FILTERS[@]-}"; do
    [[ -n "$plugin_filter" ]] || continue
    build_args+=(--plugin "$plugin_filter")
done

"$REPO_ROOT/scripts/plugins/build-local-plugins.sh" "${build_args[@]}"

asset_paths=()
while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    zip_path="$("$REPO_ROOT/scripts/plugins/build-plugin-package.sh" \
        --source "$package" \
        --output-dir "$ASSETS_DIR" \
        --zip)"
    asset_paths+=("$zip_path")
done < <(find "$BUILD_DIR/Packages" -maxdepth 1 -type d -name '*.mactoolsplugin' -print | sort)

if [[ ${#asset_paths[@]} -eq 0 ]]; then
    echo "No plugin packages were built under $BUILD_DIR/Packages." >&2
    exit 1
fi

catalog_args=(
    --mode release
    --base-url "$BASE_URL"
    --output "$CATALOG_OUTPUT"
    --plugins-root "$SOURCE_DIR"
)
if [[ -n "$MINIMUM_HOST_VERSION" ]]; then
    catalog_args+=(--minimum-host-version "$MINIMUM_HOST_VERSION")
fi
if [[ -n "$NIGHTLY_BUILD_NUMBER" ]]; then
    catalog_args+=(--nightly-build-number "$NIGHTLY_BUILD_NUMBER")
fi
if [[ -n "$RELEASE_NOTES_URL" ]]; then
    catalog_args+=(--release-notes-url "$RELEASE_NOTES_URL")
fi
for asset in "${asset_paths[@]}"; do
    catalog_args+=(--package "$asset")
done

"$REPO_ROOT/scripts/plugins/generate-plugin-catalog.sh" "${catalog_args[@]}"

if [[ -n "$SIGNED_CATALOG_OUTPUT" ]]; then
    PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$CATALOG_PRIVATE_KEY_BASE64" \
        "$REPO_ROOT/scripts/plugins/sign-plugin-catalog.sh" \
        --input "$CATALOG_OUTPUT" \
        --output "$SIGNED_CATALOG_OUTPUT"
fi

echo "Built ${#asset_paths[@]} plugin release asset(s)."
echo "Assets: $ASSETS_DIR"
echo "Catalog: $CATALOG_OUTPUT"
if [[ -n "$SIGNED_CATALOG_OUTPUT" ]]; then
    echo "Signed catalog: $SIGNED_CATALOG_OUTPUT"
fi
