#!/usr/bin/env bash
set -euo pipefail

# Runs every macOS beta probe in scripts/beta-probes serially and summarizes
# the results. All probes are strictly read-only (no event synthesis, no
# screenshots, no SMC/gamma/NightShift writes, no sudo, nothing resident).
#
# Usage:
#   ./scripts/beta-probes/run-all.sh
#
# Exit code: 0 when no probe reports [broken], 1 otherwise (2 = setup error).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift toolchain not found on PATH" >&2
    exit 2
fi

# "<file>:<timeout seconds>" — log show needs headroom for three invocations.
PROBES=(
    "probe-gamma.swift:120"
    "probe-window-topology.swift:120"
    "probe-private-input.swift:120"
    "probe-display-private.swift:120"
    "probe-iokit-ddc.swift:180"
    "probe-smc-readonly.swift:120"
    "probe-events-permissions.swift:120"
    "probe-log-show.swift:420"
    "probe-plugin-trust.swift:180"
)

RESULTS_FILE="$(mktemp -t beta-probes-results)"
PROBE_OUTPUT_FILE="$(mktemp -t beta-probe-output)"
trap 'rm -f "$RESULTS_FILE" "$PROBE_OUTPUT_FILE"' EXIT

RESULT_PATTERN='^\[(ok|degraded|broken|inconclusive|skip)\] '

run_probe() {
    local file="$1"
    local timeout_seconds="$2"
    local probe_label="${file%.swift}"

    echo "── ${file} (timeout ${timeout_seconds}s)"

    : > "$PROBE_OUTPUT_FILE"

    # Probe + watchdog run inside one subshell whose stderr is discarded: the
    # probe's own stderr is already captured in PROBE_OUTPUT_FILE, so the
    # subshell stderr only ever carries bash job-control noise ("Terminated:
    # 15 ...") printed when the watchdog reaps a timed-out probe. The TERM
    # reaches only the swift driver; a child it spawned (e.g. `log show`) may
    # be briefly orphaned, bounded by the probes' own --last 1m / internal
    # watchdogs.
    local exit_code=0
    (
        swift "$SCRIPT_DIR/$file" > "$PROBE_OUTPUT_FILE" 2>&1 &
        probe_pid=$!
        (
            for ((elapsed = 0; elapsed < timeout_seconds; elapsed++)); do
                sleep 1
                kill -0 "$probe_pid" 2>/dev/null || exit 0
            done
            kill -TERM "$probe_pid" 2>/dev/null || true
        ) &
        watchdog_pid=$!
        probe_rc=0
        wait "$probe_pid" || probe_rc=$?
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" || true
        exit "$probe_rc"
    ) 2>/dev/null || exit_code=$?

    cat "$PROBE_OUTPUT_FILE"
    grep -E "$RESULT_PATTERN" "$PROBE_OUTPUT_FILE" >> "$RESULTS_FILE" || true

    # SIGTERM from the watchdog surfaces as 143 (128 + 15).
    local synthesized=""
    if [[ $exit_code -eq 143 ]]; then
        synthesized="[inconclusive] ${probe_label}: timed out after ${timeout_seconds}s and was terminated"
    elif [[ $exit_code -ne 0 ]]; then
        synthesized="[broken] ${probe_label}: probe exited rc=${exit_code} (crash or compile failure — likely an SDK/ABI change)"
    elif ! grep -qE "$RESULT_PATTERN" "$PROBE_OUTPUT_FILE"; then
        synthesized="[inconclusive] ${probe_label}: produced no probe result lines"
    fi
    if [[ -n "$synthesized" ]]; then
        echo "$synthesized"
        echo "$synthesized" >> "$RESULTS_FILE"
    fi
}

for entry in "${PROBES[@]}"; do
    run_probe "${entry%%:*}" "${entry##*:}"
done

echo
echo "== Probe result summary =="
cat "$RESULTS_FILE"
echo
echo "== Status counts =="
total=0
broken_count=0
for status in ok degraded broken inconclusive skip; do
    count="$(grep -c "^\[${status}\] " "$RESULTS_FILE" || true)"
    printf '%-13s %s\n' "$status" "$count"
    total=$((total + count))
    if [[ "$status" == "broken" ]]; then
        broken_count=$count
    fi
done
printf '%-13s %s\n' "total" "$total"

if [[ $broken_count -gt 0 ]]; then
    echo
    echo "BROKEN probes detected:"
    grep '^\[broken\] ' "$RESULTS_FILE"
    exit 1
fi
