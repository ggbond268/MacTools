#!/bin/bash
# Headless App Uninstaller planning adapter for the vendored Mole engine.

set -euo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENGINE_REVISION="$(cat "$ENGINE_ROOT/REVISION")"

export NO_COLOR=1
export MO_NO_OPLOG=1
export MOLE_DRY_RUN=1
export MOLE_DELETE_MODE=trash
export MOLE_TEST_NO_AUTH=1

# The embedded adapter never installs, updates, or executes a destructive Mole
# command. It loads the same discovery and protection functions as the CLI and
# returns a versioned plan for MacTools to review and execute independently.
source "$ENGINE_ROOT/lib/core/common.sh"
source "$ENGINE_ROOT/lib/uninstall/brew.sh"
source "$ENGINE_ROOT/lib/uninstall/steam.sh"
source "$ENGINE_ROOT/lib/uninstall/batch.sh"

json_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\b'/\\b}"
    value="${value//$'\f'/\\f}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '"%s"' "$value"
}

candidate_id() {
    local kind="$1"
    local path="$2"
    printf '%s\0%s\0%s' "$ENGINE_REVISION" "$kind" "$path" | shasum -a 256 | awk '{print $1}'
}

candidate_kind() {
    local path="$1"
    case "$path" in
        "$HOME/Library/Caches/"*) printf 'cache' ;;
        "$HOME/Library/Logs/"*) printf 'log' ;;
        "$HOME/Library/Preferences/"*) printf 'preference' ;;
        "$HOME/Library/Saved Application State/"*) printf 'saved_state' ;;
        "$HOME/Library/Application Support/"*) printf 'support' ;;
        "$HOME/Library/Containers/"*) printf 'container' ;;
        "$HOME/Library/Group Containers/"*) printf 'group_container' ;;
        *) printf 'associated' ;;
    esac
}

emit_candidate() {
    local path="$1"
    local kind="$2"
    local selected="$3"
    local review_only="$4"
    local prefix="$5"
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ "$prefix" == "false" ]]; then
        printf ',\n'
    fi
    printf '    {"id": '
    json_quote "$(candidate_id "$kind" "$path")"
    printf ', "path": '
    json_quote "$path"
    printf ', "kind": '
    json_quote "$kind"
    printf ', "selected_by_default": %s, "review_only": %s}' "$selected" "$review_only"
}

plan_application() {
    local app_path="$1"
    [[ "$app_path" == /* && "$app_path" == *.[aA][pP][pP] && -d "$app_path" ]] || {
        printf 'The selected path is not an application bundle.\n' >&2
        return 2
    }
    [[ "$app_path" != *'|'* && "$app_path" != *$'\n'* && "$app_path" != *$'\r'* ]] || {
        printf 'Application paths containing control or record-separator characters are unsupported.\n' >&2
        return 2
    }

    local info="$app_path/Contents/Info.plist"
    [[ -f "$info" ]] || {
        printf 'The application Info.plist is unavailable.\n' >&2
        return 2
    }

    local bundle_id app_name package_type executable
    bundle_id=$(plutil -extract CFBundleIdentifier raw "$info" 2> /dev/null || true)
    package_type=$(plutil -extract CFBundlePackageType raw "$info" 2> /dev/null || true)
    executable=$(plutil -extract CFBundleExecutable raw "$info" 2> /dev/null || true)
    app_name="${app_path##*/}"
    app_name="${app_name%.[aA][pP][pP]}"
    [[ "$package_type" == "APPL" && -n "$bundle_id" && -n "$executable" && -e "$app_path/Contents/MacOS/$executable" ]] || {
        printf 'The selected bundle does not have a complete application identity.\n' >&2
        return 2
    }
    mole_is_reverse_dns_bundle_id "$bundle_id" || {
        printf 'The application bundle identifier is invalid.\n' >&2
        return 2
    }

    # These names intentionally match batch.sh's dynamic-scope contract.
    local -a selected_apps=("embedded|$app_path|$app_name|$bundle_id|0||")
    local -a running_apps=()
    local -a sudo_apps=()
    local -a brew_cask_apps=()
    local -a blocked_apps=()
    local -a manual_removal_apps=()
    local -a app_details=()
    local total_estimated_size=0
    local _batch_scan_stage="application inspection"
    local _batch_scan_app_name=""
    local scan_log
    scan_log=$(create_temp_file) || return 1
    local scan_rc=0
    _batch_scan_app_details > "$scan_log" 2>&1 || scan_rc=$?
    if [[ -s "$scan_log" ]]; then
        cat "$scan_log" >&2
    fi
    rm -f "$scan_log" 2> /dev/null || true
    [[ $scan_rc -eq 0 ]] || return "$scan_rc"

    local status="ready"
    local source="standalone"
    local blocked_reason=""
    if [[ ${#blocked_apps[@]} -gt 0 ]]; then
        status="blocked"
        source="vendor"
        blocked_reason="An official vendor uninstaller is required."
    elif [[ ${#manual_removal_apps[@]} -gt 0 ]]; then
        status="blocked"
        source="manual"
        blocked_reason="Mole could not safely prepare this application for removal."
    elif [[ ${#app_details[@]} -ne 1 ]]; then
        printf 'Mole did not produce exactly one application plan.\n' >&2
        return 1
    fi

    local detail="${app_details[0]-}"
    local total_kb=0 encoded_files="" needs_sudo=false is_brew=false cask_name=""
    local encoded_review="" sibling_guard="none" app_identity="" info_identity=""
    if [[ -n "$detail" ]]; then
        local _detail_name _detail_path _detail_bundle _encoded_system _sensitive _encoded_diag _encoded_helpers _original_bundle _sibling_fingerprint
        IFS='|' read -r _detail_name _detail_path _detail_bundle total_kb encoded_files _encoded_system _sensitive needs_sudo is_brew cask_name _encoded_diag encoded_review _encoded_helpers sibling_guard app_identity _original_bundle _sibling_fingerprint info_identity <<< "$detail"
        if [[ "$is_brew" == "true" ]]; then
            source="homebrew"
            status="blocked"
            blocked_reason="This application is managed by Homebrew."
        fi
    fi

    local related_files=""
    local review_files=""
    [[ -n "$encoded_files" ]] && related_files=$(decode_file_list "$encoded_files" "$app_name")
    [[ -n "$encoded_review" ]] && review_files=$(decode_file_list "$encoded_review" "$app_name")

    local plan_material="$ENGINE_REVISION|$app_path|$bundle_id|$app_identity|$info_identity|$encoded_files|$encoded_review"
    local plan_id
    plan_id=$(printf '%s' "$plan_material" | shasum -a 256 | awk '{print $1}')

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "engine": {"name": "Mole", "revision": '
    json_quote "$ENGINE_REVISION"
    printf '},\n'
    printf '  "plan_id": '
    json_quote "$plan_id"
    printf ',\n  "status": '
    json_quote "$status"
    printf ',\n  "source": '
    json_quote "$source"
    printf ',\n  "blocked_reason": '
    if [[ -n "$blocked_reason" ]]; then json_quote "$blocked_reason"; else printf 'null'; fi
    printf ',\n  "application": {"name": '
    json_quote "$app_name"
    printf ', "path": '
    json_quote "$app_path"
    printf ', "bundle_id": '
    json_quote "$bundle_id"
    printf ', "identity": '
    json_quote "$app_identity"
    printf ', "info_identity": '
    json_quote "$info_identity"
    printf '},\n'
    printf '  "requires_sudo": %s,\n' "$needs_sudo"
    printf '  "homebrew_cask": '
    if [[ -n "$cask_name" ]]; then json_quote "$cask_name"; else printf 'null'; fi
    printf ',\n  "sibling_guard": '
    json_quote "$sibling_guard"
    printf ',\n  "estimated_kilobytes": %s,\n' "${total_kb:-0}"
    printf '  "candidates": [\n'

    local first=true
    if [[ -e "$app_path" ]]; then
        emit_candidate "$app_path" "application" "true" "false" "$first"
        first=false
    fi
    local candidate kind selected
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        kind=$(candidate_kind "$candidate")
        selected=false
        case "$kind" in
            cache | log | preference | saved_state) selected=true ;;
        esac
        emit_candidate "$candidate" "$kind" "$selected" "false" "$first"
        first=false
    done <<< "$related_files"
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        kind=$(candidate_kind "$candidate")
        emit_candidate "$candidate" "$kind" "false" "true" "$first"
        first=false
    done <<< "$review_files"

    printf '\n  ],\n'
    printf '  "warnings": ['
    local warning_first=true
    if [[ "$sibling_guard" != "none" ]]; then
        json_quote "Another installed copy may share data; Mole narrowed the plan."
        warning_first=false
    fi
    if [[ -n "$review_files" ]]; then
        [[ "$warning_first" == "false" ]] && printf ', '
        json_quote "System-level remnants are review-only and are not removable by this plan."
    fi
    printf ']\n}\n'
}

main() {
    [[ $# -eq 3 && "$1" == "plan" && "$2" == "--app" ]] || {
        printf 'Usage: mactools-engine.sh plan --app /absolute/path/App.app\n' >&2
        return 2
    }
    plan_application "$3"
}

main "$@"
