#!/bin/bash
set -euo pipefail

# Compile a synthetic probe against already-built plugin products. Never installs the app.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
configuration="${1:-Release}"
probe="${2:-panel}"
case "$configuration" in Debug|Release) ;; *) echo "Expected Debug or Release" >&2; exit 2 ;; esac
case "$probe" in panel|previews|window) ;; *) echo "Expected panel, previews, or window" >&2; exit 2 ;; esac
products="$repo_root/build/DerivedData/Build/Products/$configuration"
output="$repo_root/build/ClipboardBenchmarks/$configuration"
if [[ ! -f "$products/libClipboardHistoryPluginCore.a" ]]; then
    echo "Build ClipboardHistoryPlugin with ENABLE_TESTABILITY=YES first." >&2
    exit 1
fi
mkdir -p "$output"
optimization=(-Onone)
if [[ "$configuration" == Release ]]; then optimization=(-O); fi
entry_point=()
if [[ "$probe" == window ]]; then entry_point=(-parse-as-library); fi
xcrun swiftc "${optimization[@]}" "${entry_point[@]}" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/scripts/benchmarks/clipboard-$probe.swift" \
    -module-cache-path "$repo_root/build/ClipboardBenchmarks/ModuleCache" \
    -I "$products" -F "$products" -L "$products" \
    -lClipboardHistoryPluginCore -framework MacToolsPluginKit -lsqlite3 \
    -Xlinker -rpath -Xlinker "$products" -o "$output/clipboard-$probe"
"$output/clipboard-$probe" "${@:3}"
