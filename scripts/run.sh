#!/usr/bin/env bash
#
# Run each reproducer N times and report how often it died with SIGSEGV.
#
#   scripts/run.sh [runs]
#
# Exit status is 0 if every run of every reproducer behaved as expected:
#   * standalone/main      : SIGSEGV every time (exit status 139)
#   * standalone/main-linked: exit status 0 every time
#   * python/mesh_exit.py  : SIGSEGV every time (exit status 139)
#   * standalone/main with LD_PRELOAD=libtcm.so.1: exit status 0 every time
#
# Note: the crash is at process exit, *after* "work done" / "mesh done" has
# been printed.  A run that prints the message and then dies is a success for
# this reproducer.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${1:-5}"
RUNTIME="${RUNTIME:-$ROOT/runtime}"
PYTHON="${PYTHON:-python3}"

export LD_LIBRARY_PATH="$RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

status=0

report() { # <name> <expected-exit> <actual-exits...>
    local name="$1" expected="$2"; shift 2
    local ok=0 fail=0 rc
    for rc in "$@"; do
        if [ "$rc" = "$expected" ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done
    if [ "$fail" -eq 0 ]; then
        printf 'PASS  %-42s %d/%d exit=%s\n' "$name" "$ok" "$((ok + fail))" "$expected"
    else
        printf 'FAIL  %-42s %d/%d exit=%s (got: %s)\n' \
            "$name" "$ok" "$((ok + fail))" "$expected" "$*"
        status=1
    fi
}

collect() { # <cmd...> -> prints exit codes
    local -a rcs=()
    local i
    for ((i = 0; i < RUNS; i++)); do
        "$@" >/dev/null 2>&1
        rcs+=("$?")
    done
    printf '%s\n' "${rcs[@]}"
}

mapfile -t rcs < <(collect "$ROOT/standalone/main" "$ROOT/standalone/libwork.so")
report "standalone (dlopen oneTBB)" 139 "${rcs[@]}"

mapfile -t rcs < <(collect "$ROOT/standalone/main-linked")
report "standalone control (DT_NEEDED oneTBB)" 0 "${rcs[@]}"

mapfile -t rcs < <(collect env LD_PRELOAD="$RUNTIME/libtcm.so.1" "$ROOT/standalone/main" "$ROOT/standalone/libwork.so")
report "standalone with LD_PRELOAD=libtcm.so.1" 0 "${rcs[@]}"

mapfile -t rcs < <(collect env PYTHONPATH="$ROOT/python" "$PYTHON" -X dev "$ROOT/python/mesh_exit.py")
report "python -X dev mesh_exit.py" 139 "${rcs[@]}"

exit "$status"
