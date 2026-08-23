#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"

CLI_ARCHIVE=""
DMG_PATH=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
ALLOW_UNSIGNED=0
CHECK_GATEKEEPER=0

function fail() {
  printf '[artifact-validation] error: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-archive) CLI_ARCHIVE="${2:-}"; shift 2 ;;
    --dmg) DMG_PATH="${2:-}"; shift 2 ;;
    --version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --build) EXPECTED_BUILD="${2:-}"; shift 2 ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --gatekeeper) CHECK_GATEKEEPER=1; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -f "$CLI_ARCHIVE" ]] || fail "CLI archive not found: $CLI_ARCHIVE"
[[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"
[[ -n "$EXPECTED_VERSION" ]] || fail "Expected version is required."
[[ -n "$EXPECTED_BUILD" ]] || fail "Expected build is required."

STAGE_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mactools-artifact-validation.XXXXXX")"
MOUNT_POINT=""
function cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

/usr/bin/python3 - "$CLI_ARCHIVE" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    infos = archive.infolist()
    if [info.filename for info in infos] != ["mactools"]:
        raise SystemExit("CLI archive must contain exactly one root entry named mactools")
    mode = infos[0].external_attr >> 16
    if not stat.S_ISREG(mode) or mode & 0o7777 != 0o755:
        raise SystemExit("CLI archive entry must be a regular executable with exact mode 0755")
PY

/usr/bin/ditto -x -k "$CLI_ARCHIVE" "$STAGE_DIR/cli"
CLI_PATH="$STAGE_DIR/cli/mactools"
[[ -x "$CLI_PATH" && ! -L "$CLI_PATH" ]] || fail "Extracted CLI is not a regular executable."

function validate_universal_binary() {
  local path="$1"
  local role="$2"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$path")"
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" architectures \
    --value "$architectures" \
    --role "$role"
}

validate_universal_binary "$CLI_PATH" "CLI"

function signing_detail() {
  /usr/bin/codesign -dvvv "$1" 2>&1 \
    | /usr/bin/awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }'
}

function validate_embedded_info() {
  local path="$1"
  local architecture="$2"
  local expected_identifier="$3"
  local plist_path="$STAGE_DIR/$(/usr/bin/basename "$path").$architecture.plist"
  /usr/bin/otool -arch "$architecture" -s __TEXT __info_plist "$path" \
    | /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" extract-info \
    > "$plist_path"
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" info \
    --plist "$plist_path" \
    --identifier "$expected_identifier" \
    --version "$EXPECTED_VERSION" \
    --build "$EXPECTED_BUILD" \
    --role "$path ($architecture)"
}

function validate_signed_role() {
  local path="$1"
  local expected_identifier="$2"
  local expected_team="$3"
  local status=0
  local details_path="$STAGE_DIR/$(/usr/bin/basename "$path").signing.txt"
  /usr/bin/codesign --verify --strict --verbose=2 "$path" >/dev/null 2>&1 || status=$?
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" status \
    --value "$status" \
    --operation "Signature verification for $path"
  /usr/bin/codesign -dvvv "$path" > /dev/null 2> "$details_path"
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" signing \
    --details "$details_path" \
    --identifier "$expected_identifier" \
    --team "$expected_team" \
    --role "$path"
}

ATTACH_PLIST="$STAGE_DIR/attach.plist"
/usr/bin/hdiutil attach -readonly -nobrowse -plist "$DMG_PATH" > "$ATTACH_PLIST"
MOUNT_POINT="$(/usr/bin/python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
for entity in value.get("system-entities", []):
    mount = entity.get("mount-point")
    if mount:
        print(mount)
        break
PY
)"
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || fail "Could not mount DMG."

APP_PATH="$MOUNT_POINT/MacTools.app"
[[ -d "$APP_PATH" ]] || fail "DMG must contain MacTools.app at its root."
APP_COUNT="$(/usr/bin/find "$MOUNT_POINT" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$APP_COUNT" == "1" ]] || fail "DMG must contain exactly one root-level app."

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$APP_VERSION" == "$EXPECTED_VERSION" && "$APP_BUILD" == "$EXPECTED_BUILD" ]] \
  || fail "App version/build does not match the CLI release."

HOST_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
HOST_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
/usr/bin/python3 "$SCRIPT_DIR/validate-release-layout.py" \
  --app "$APP_PATH" \
  --host-executable "$HOST_EXECUTABLE" \
  --host-identifier "$HOST_IDENTIFIER"
BROKER_PATH="$APP_PATH/Contents/MacOS/MacToolsCLIBroker"
[[ -x "$BROKER_PATH" ]] || fail "DMG app is missing MacToolsCLIBroker."
validate_universal_binary "$BROKER_PATH" "Broker"

for architecture in arm64 x86_64; do
  validate_embedded_info "$CLI_PATH" "$architecture" "$HOST_IDENTIFIER.cli"
done
for architecture in arm64 x86_64; do
  validate_embedded_info "$BROKER_PATH" "$architecture" "$HOST_IDENTIFIER.cli-broker"
done

if [[ "$ALLOW_UNSIGNED" -eq 0 ]]; then
  APP_SIGNATURE_STATUS=0
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 \
    || APP_SIGNATURE_STATUS=$?
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" status \
    --value "$APP_SIGNATURE_STATUS" \
    --operation "App signature verification"
  HOST_TEAM="$(signing_detail "$APP_PATH" TeamIdentifier)"
  [[ -n "$HOST_TEAM" ]] || fail "App signature has no Team Identifier."
  validate_signed_role "$APP_PATH" "$HOST_IDENTIFIER" "$HOST_TEAM"
  validate_signed_role "$BROKER_PATH" "$HOST_IDENTIFIER.cli-broker" "$HOST_TEAM"
  validate_signed_role "$CLI_PATH" "$HOST_IDENTIFIER.cli" "$HOST_TEAM"
fi

if [[ "$CHECK_GATEKEEPER" -eq 1 ]]; then
  DMG_GATEKEEPER_STATUS=0
  CLI_GATEKEEPER_STATUS=0
  /usr/sbin/spctl -a -t open --context context:primary-signature -v "$DMG_PATH" \
    || DMG_GATEKEEPER_STATUS=$?
  /usr/sbin/spctl -a -t exec -v "$CLI_PATH" || CLI_GATEKEEPER_STATUS=$?
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" status \
    --value "$DMG_GATEKEEPER_STATUS" \
    --operation "DMG Gatekeeper assessment"
  /usr/bin/python3 "$SCRIPT_DIR/release_binary_validation.py" status \
    --value "$CLI_GATEKEEPER_STATUS" \
    --operation "CLI Gatekeeper assessment"
fi

printf '[artifact-validation] app, broker, and standalone CLI passed\n'
