#!/bin/zsh

set -euo pipefail

if [[ $# -ne 3 ]]; then
    print -u2 -r -- "usage: $0 <built-app> <installed-app> <expected-bundle-identifier>"
    exit 2
fi

source_app="${1:A}"
installed_app="${2:A}"
expected_bundle_identifier="$3"
install_parent="${installed_app:h}"
expected_parent="${HOME:A}/Applications"

[[ -d "$source_app" && "${source_app:e}" == app ]] || {
    print -u2 -r -- "error: built app not found at $source_app"
    exit 1
}
[[ "$install_parent" == "$expected_parent" && "${installed_app:e}" == app ]] || {
    print -u2 -r -- "error: debug app target must be an app directly inside $expected_parent"
    exit 1
}

/bin/mkdir -p "$install_parent"
stage_root="$(/usr/bin/mktemp -d "$install_parent/.mactools-debug-install.XXXXXX")"
staged_app="$stage_root/${installed_app:t}"
backup_app="$stage_root/previous.app"
staged_requirement="$stage_root/designated-requirement.staged.txt"
retained_requirement="$stage_root/designated-requirement.retained.txt"
installed_requirement="$stage_root/designated-requirement.installed.txt"
replacement_started=false
replacement_committed=false
had_previous=false

read_bundle_value() {
    local app_path="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist" 2>/dev/null
}

validate_bundle() {
    local app_path="$1"
    local bundle_id executable_name
    bundle_id="$(read_bundle_value "$app_path" CFBundleIdentifier)" || return 1
    executable_name="$(read_bundle_value "$app_path" CFBundleExecutable)" || return 1
    [[ -n "$bundle_id" && -n "$executable_name" \
        && "$executable_name" == "${executable_name:t}" \
        && -x "$app_path/Contents/MacOS/$executable_name" ]]
}

capture_designated_requirement() {
    local app_path="$1"
    local output_path="$2"
    /usr/bin/codesign -d -r- "$app_path" 2>&1 \
        | /usr/bin/sed -n \
            -e 's/^# designated => //p' \
            -e 's/^designated => //p' >"$output_path"
    [[ -s "$output_path" ]]
}

cleanup() {
    if [[ "$replacement_started" == true \
        && "$replacement_committed" != true \
        && -d "$backup_app" ]]; then
        if [[ -d "$installed_app" ]]; then
            /bin/mv "$installed_app" "$stage_root/rejected.app" >/dev/null 2>&1 || true
        fi
        /bin/mv "$backup_app" "$installed_app" >/dev/null 2>&1 || true
    fi
    if [[ -d "$stage_root" ]]; then
        /bin/rm -rf "$stage_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto --rsrc --extattr --acl "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
validate_bundle "$staged_app" || {
    print -u2 -r -- "error: staged Debug app has invalid bundle identity or executable metadata"
    exit 1
}
staged_bundle_identifier="$(read_bundle_value "$staged_app" CFBundleIdentifier)"
staged_executable_name="$(read_bundle_value "$staged_app" CFBundleExecutable)"
if [[ "$staged_bundle_identifier" != "$expected_bundle_identifier" ]]; then
    print -u2 -r -- "error: staged Debug app bundle identifier '$staged_bundle_identifier' does not match configured identity '$expected_bundle_identifier'"
    exit 1
fi
capture_designated_requirement "$staged_app" "$staged_requirement" || {
    print -u2 -r -- "error: staged Debug app has no designated signing requirement"
    exit 1
}

if [[ -d "$installed_app" ]]; then
    had_previous=true
    /usr/bin/codesign --verify --deep --strict "$installed_app"
    validate_bundle "$installed_app" || {
        print -u2 -r -- "error: retained Debug app has invalid bundle identity or executable metadata"
        exit 1
    }
    retained_bundle_identifier="$(read_bundle_value "$installed_app" CFBundleIdentifier)"
    retained_executable_name="$(read_bundle_value "$installed_app" CFBundleExecutable)"
    capture_designated_requirement "$installed_app" "$retained_requirement" || {
        print -u2 -r -- "error: retained Debug app has no designated signing requirement"
        exit 1
    }
    if [[ "$retained_bundle_identifier" != "$staged_bundle_identifier" \
        || "$retained_executable_name" != "$staged_executable_name" ]] \
        || ! /usr/bin/cmp -s "$retained_requirement" "$staged_requirement"; then
        print -u2 -r -- "error: staged Debug app identity does not match the retained app"
        exit 1
    fi
fi

installed_executable="$installed_app/Contents/MacOS/$staged_executable_name"
running_pids=()
while read -r pid command; do
    if [[ "$command" == "$installed_executable" || "$command" == "$installed_executable "* ]]; then
        running_pids+=("$pid")
        /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
done < <(/bin/ps -axo pid=,command=)

for pid in "${running_pids[@]}"; do
    for _ in {1..50}; do
        /bin/kill -0 "$pid" >/dev/null 2>&1 || break
        /bin/sleep 0.1
    done
    if /bin/kill -0 "$pid" >/dev/null 2>&1; then
        print -u2 -r -- "error: existing Debug app process $pid did not terminate"
        exit 1
    fi
done

if [[ "$had_previous" == true ]]; then
    replacement_started=true
    /bin/mv "$installed_app" "$backup_app"
    case "${MACTOOLS_INSTALL_DEBUG_TEST_INTERRUPT_AFTER_BACKUP:-}" in
        INT) /bin/kill -INT "$$" ;;
        TERM) /bin/kill -TERM "$$" ;;
    esac
fi

if ! /bin/mv "$staged_app" "$installed_app"; then
    if [[ "$had_previous" == true && -d "$backup_app" ]]; then
        /bin/mv "$backup_app" "$installed_app"
    fi
    exit 1
fi
replacement_started=true

if [[ "$had_previous" == true ]]; then
    validate_bundle "$installed_app" || {
        /bin/mv "$installed_app" "$stage_root/rejected.app"
        /bin/mv "$backup_app" "$installed_app"
        print -u2 -r -- "error: replacement app metadata changed; restored the previous app"
        exit 1
    }
    installed_bundle_identifier="$(read_bundle_value "$installed_app" CFBundleIdentifier)"
    installed_executable_name="$(read_bundle_value "$installed_app" CFBundleExecutable)"
    capture_designated_requirement "$installed_app" "$installed_requirement" || true
    if [[ "$installed_bundle_identifier" != "$staged_bundle_identifier" \
        || "$installed_executable_name" != "$staged_executable_name" ]] \
        || ! /usr/bin/cmp -s "$retained_requirement" "$installed_requirement"; then
        /bin/mv "$installed_app" "$stage_root/rejected.app"
        /bin/mv "$backup_app" "$installed_app"
        print -u2 -r -- "error: app identity changed; restored the previous app so macOS permissions remain valid"
        exit 1
    fi
fi

lsregister="${MACTOOLS_LSREGISTER_PATH:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
if [[ -x "$lsregister" ]]; then
    bundle_identifier="$staged_bundle_identifier"
    app_name="${installed_app:t:r}"
    while IFS= read -r registered_app; do
        registered_app="${registered_app:A}"
        [[ -n "$registered_app" && "$registered_app" != "$installed_app" ]] || continue
        "$lsregister" -u "$registered_app" >/dev/null 2>&1 || true
    done < <(
        "$lsregister" -dump | /usr/bin/awk \
            -v target="$bundle_identifier" \
            -v target_name="$app_name" \
            -v keep="$installed_app" '
                function emit() {
                    if ((identifier == target || name == target_name) \
                        && path != "" && path != keep) print path
                }
                /^-+$/ {
                    emit()
                    path = ""
                    identifier = ""
                    name = ""
                    next
                }
                /^[[:space:]]*path:[[:space:]]*/ {
                    value = $0
                    sub(/^[[:space:]]*path:[[:space:]]*/, "", value)
                    sub(/ \(0x[0-9a-fA-F]+\)$/, "", value)
                    path = value
                    next
                }
                /^[[:space:]]*identifier:[[:space:]]*/ {
                    value = $0
                    sub(/^[[:space:]]*identifier:[[:space:]]*/, "", value)
                    identifier = value
                    next
                }
                /^[[:space:]]*name:[[:space:]]*/ {
                    value = $0
                    sub(/^[[:space:]]*name:[[:space:]]*/, "", value)
                    name = value
                    next
                }
                END { emit() }
            '
    )
    "$lsregister" -u "$source_app" >/dev/null 2>&1 || true
    "$lsregister" -f "$installed_app" >/dev/null 2>&1 || true
fi

replacement_committed=true

print -r -- "Installed verified Debug app: $installed_app"
