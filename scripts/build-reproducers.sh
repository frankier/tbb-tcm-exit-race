#!/usr/bin/env bash
#
# Build the two minimal reproducers against the build-local oneTBB in
# ./runtime.  Run scripts/build-onetbb.sh first.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${WORK:-$ROOT/.work}"
RUNTIME="${RUNTIME:-$ROOT/runtime}"
ONETBB_SRC="${ONETBB_SRC:-$WORK/oneTBB}"
ONETBB_INC="${ONETBB_INC:-$RUNTIME/include}"

log() { printf '==> %s\n' "$*" >&2; }

[ -d "$ONETBB_INC" ] || { log "error: $ONETBB_INC not found; run scripts/build-onetbb.sh first" >&2; exit 1; }
[ -e "$RUNTIME/libtbb.so.12" ] || { log "error: $RUNTIME/libtbb.so.12 not found; run scripts/build-onetbb.sh first" >&2; exit 1; }

CXX="${CXX:-g++}"
CC="${CC:-gcc}"
CXXFLAGS_COMMON=(-O2 -g -std=c++17 -fPIC)
LDFLAGS_RUNTIME=(-L"$RUNTIME" -Wl,-rpath,"$RUNTIME")

# ---------------------------------------------------------------------------
# Standalone reproducer: host dlopen()s a oneTBB-using library.
# ---------------------------------------------------------------------------
log "building standalone/libwork.so"
"$CXX" -shared "${CXXFLAGS_COMMON[@]}" \
    "$ROOT/standalone/work.cpp" \
    -I"$ONETBB_INC" "${LDFLAGS_RUNTIME[@]}" -ltbb \
    -o "$ROOT/standalone/libwork.so"

log "building standalone/main (dlopen host)"
"$CC" -O2 -g "$ROOT/standalone/main.c" -ldl -o "$ROOT/standalone/main"

log "building standalone/main-linked (control, oneTBB as DT_NEEDED)"
"$CXX" "${CXXFLAGS_COMMON[@]}" \
    "$ROOT/standalone/main-linked.cpp" \
    -I"$ONETBB_INC" "${LDFLAGS_RUNTIME[@]}" -ltbb \
    -o "$ROOT/standalone/main-linked"

# ---------------------------------------------------------------------------
# Python reproducer: native CPython C API, no nanobind.
# ---------------------------------------------------------------------------
PYTHON="${PYTHON:-python3}"
PY_INCLUDES="$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_path("include"))')"
EXT_SUFFIX="$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')"

log "building python/apitoflite$EXT_SUFFIX"
"$CXX" -shared "${CXXFLAGS_COMMON[@]}" \
    "$ROOT/python/apitoflite.cpp" \
    -I"$PY_INCLUDES" -I"$ONETBB_INC" \
    "${LDFLAGS_RUNTIME[@]}" -ltbb \
    -o "$ROOT/python/apitoflite$EXT_SUFFIX"

log "done."
