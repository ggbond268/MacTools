#!/bin/bash
# Mole - Steam launcher detection
#
# Steam's "create desktop shortcut" writes a tiny shell launcher that only
# opens `steam://run/<appid>`. Its bundle size is the launcher's size, not
# the installed game, so Mole labels these apps as Steam-managed instead of
# presenting the shortcut size as the removable application size.

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_STEAM_UNINSTALL_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_STEAM_UNINSTALL_LOADED=1

# Print the Steam app id referenced by a Steam-generated launcher bundle, or
# return 1 when the bundle does not look like one.
uninstall_steam_launcher_appid() {
    local app_path="${1:-}"
    [[ -n "$app_path" && -d "$app_path" ]] || return 1

    local exec_name=""
    local plist="$app_path/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
        exec_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2> /dev/null || true)
    fi
    if [[ -z "$exec_name" ]]; then
        exec_name="${app_path##*/}"
        exec_name="${exec_name%.[aA][pP][pP]}"
    fi

    local script="$app_path/Contents/MacOS/$exec_name"
    [[ -f "$script" && -r "$script" && -x "$script" ]] || return 1

    # Steam-generated launchers are tiny shell wrappers with one active
    # command. Bound and parse the whole script so a URL in a comment, a dead
    # branch, or a larger script containing unrelated commands cannot label a
    # normal application as launcher-only.
    local script_size
    script_size=$(wc -c < "$script" 2> /dev/null | tr -d '[:space:]') || return 1
    [[ "$script_size" =~ ^[0-9]+$ && "$script_size" -le 4096 ]] || return 1

    local appid
    appid=$(LC_ALL=C awk '
        NR == 1 {
            if ($0 !~ /^#![[:space:]]*((\/usr\/bin\/env[[:space:]]+)?(\/bin\/)?(ba|z)?sh)([[:space:]]|$)/) {
                exit 1
            }
            next
        }
        {
            sub(/\r$/, "")
            if ($0 ~ /^[[:space:]]*($|#)/) {
                next
            }
            active++
            if (active > 1 || $0 !~ /^[[:space:]]*(exec[[:space:]]+)?(\/usr\/bin\/)?open[[:space:]]+["'\'' ]?steam:\/\/(run|rungameid|launch)\/[0-9]+["'\'' ]?[[:space:]]*$/) {
                exit 1
            }
            appid = $0
            sub(/^.*\//, "", appid)
            gsub(/["'\''[:space:]]/, "", appid)
        }
        END {
            if (active == 1 && appid ~ /^[0-9]+$/) {
                print appid
            } else {
                exit 1
            }
        }
    ' "$script" 2> /dev/null) || return 1
    [[ "$appid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$appid"
}

# True when app_path is a Steam-generated launcher whose bundle size is not
# the installed game size.
uninstall_app_is_steam_launcher() {
    local app_path="${1:-}"
    uninstall_steam_launcher_appid "$app_path" > /dev/null 2>&1
}
