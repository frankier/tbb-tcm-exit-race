#!/usr/bin/env bash
#
# Build a build-local, reproducibly-crashing copy of oneTBB.
#
#   * clone oneTBB at a pinned tag
#   * apply patches/*.patch (widens the libtcm exit-time race window)
#   * build libtbb.so.12 and libtcm.so.1
#   * assemble them, together with a libhwloc.so.15, in ./runtime
#
# Nothing is installed system-wide and the oneTBB checkout is not modified in
# place beyond the reproducer patch.  Re-running the script is safe.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ONETBB_REPO="${ONETBB_REPO:-https://github.com/uxlfoundation/oneTBB.git}"
ONETBB_REF="${ONETBB_REF:-v2023.1.0}"
HWLOC_VERSION="${HWLOC_VERSION:-2.13.0}"

WORK="${WORK:-$ROOT/.work}"
ONETBB_SRC="${ONETBB_SRC:-$WORK/oneTBB}"
ONETBB_BUILD="${ONETBB_BUILD:-$WORK/oneTBB-build}"
TCM_BUILD="${TCM_BUILD:-$WORK/tcm-build}"
HWLOC_PREFIX="${HWLOC_PREFIX:-$WORK/hwloc-prefix}"
RUNTIME="${RUNTIME:-$ROOT/runtime}"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
JOBS="${JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 4)}"

log() { printf '==> %s\n' "$*" >&2; }

mkdir -p "$WORK" "$RUNTIME"

# ---------------------------------------------------------------------------
# 1. oneTBB source + reproducer patch
# ---------------------------------------------------------------------------
if [ ! -d "$ONETBB_SRC" ]; then
    log "cloning oneTBB $ONETBB_REF -> $ONETBB_SRC"
    git clone --depth 1 --branch "$ONETBB_REF" "$ONETBB_REPO" "$ONETBB_SRC"
fi

if [ -d "$ONETBB_SRC/.git" ]; then
    git -C "$ONETBB_SRC" checkout -- .
else
    log "warning: $ONETBB_SRC is not a git checkout; cannot reset before patching"
fi

for patch in "$ROOT"/patches/*.patch; do
    log "applying $(basename "$patch")"
    if [ -d "$ONETBB_SRC/.git" ]; then
        git -C "$ONETBB_SRC" apply "$patch"
    else
        ( cd "$ONETBB_SRC" && patch -p1 --forward < "$patch" )
    fi
done

# ---------------------------------------------------------------------------
# 2. hwloc headers + library
#
# libtcm needs <hwloc.h> at build time.  Distributions frequently ship only the
# runtime library (libhwloc.so.15), so if no usable hwloc is found we download
# the hwloc sources, run configure (which generates config.h) and point the
# build at the system/oneAPI libhwloc.so.15.
# ---------------------------------------------------------------------------
find_hwloc_lib() {
    if [ -n "${HWLOC_LIB:-}" ] && [ -e "$HWLOC_LIB" ]; then
        printf '%s\n' "$HWLOC_LIB"
        return 0
    fi
    for candidate in \
        /usr/lib64/libhwloc.so.15 \
        /usr/lib/x86_64-linux-gnu/libhwloc.so.15 \
        /opt/intel/oneapi/redist/lib/libhwloc.so.15
    do
        [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    local from_ldconfig
    from_ldconfig="$(ldconfig -p 2>/dev/null | awk '/libhwloc\.so\.15 .*=>/ {print $NF; exit}')"
    if [ -n "$from_ldconfig" ] && [ -e "$from_ldconfig" ]; then
        printf '%s\n' "$from_ldconfig"
        return 0
    fi
    return 1
}

prepare_hwloc() {
    if [ -e "$HWLOC_PREFIX/include/hwloc.h" ] \
       && [ -e "$HWLOC_PREFIX/lib/libhwloc.so" ] \
       && [ -x "$HWLOC_PREFIX/bin/hwloc-info" ]; then
        return 0
    fi

    mkdir -p "$HWLOC_PREFIX/include" "$HWLOC_PREFIX/lib" "$HWLOC_PREFIX/bin"

    local hwloc_src="$WORK/hwloc-$HWLOC_VERSION"
    if [ ! -e "$hwloc_src/include/hwloc/autogen/config.h" ]; then
        log "downloading hwloc $HWLOC_VERSION sources (headers only)"
        local tarball="$WORK/hwloc-$HWLOC_VERSION.tar.gz"
        curl -fsSL -o "$tarball" \
            "https://download.open-mpi.org/release/hwloc/v${HWLOC_VERSION%.*}/hwloc-$HWLOC_VERSION.tar.gz"
        tar -xzf "$tarball" -C "$WORK"
        log "configuring hwloc (generates hwloc/autogen/config.h)"
        ( cd "$hwloc_src" && ./configure --prefix="$HWLOC_PREFIX" \
              --disable-io --disable-libudev --disable-doxygen \
              >"$WORK/hwloc-configure.log" 2>&1 )
    fi

    ln -sfn "$hwloc_src/include/hwloc.h" "$HWLOC_PREFIX/include/hwloc.h"
    ln -sfn "$hwloc_src/include/hwloc"   "$HWLOC_PREFIX/include/hwloc"

    local hwloc_lib
    if ! hwloc_lib="$(find_hwloc_lib)"; then
        log "error: could not find libhwloc.so.15; set HWLOC_LIB" >&2
        return 1
    fi
    log "using hwloc headers from $hwloc_src, library $hwloc_lib"
    ln -sfn "$hwloc_lib" "$HWLOC_PREFIX/lib/libhwloc.so"

    # FindHWLOC.cmake probes `hwloc-info --version`; provide a stub.
    printf '#!/bin/sh\necho %s\n' "$HWLOC_VERSION" > "$HWLOC_PREFIX/bin/hwloc-info"
    chmod +x "$HWLOC_PREFIX/bin/hwloc-info"
}

prepare_hwloc

# ---------------------------------------------------------------------------
# 3. libtbb
# ---------------------------------------------------------------------------
log "building libtbb"
cmake -S "$ONETBB_SRC" -B "$ONETBB_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DTBB_TEST=OFF -DTBB_EXAMPLES=OFF -DTBB_STRICT=OFF -DTBB4PY_BUILD=OFF \
    >"$WORK/libtbb-configure.log" 2>&1
ninja -C "$ONETBB_BUILD" -j"$JOBS" tbb

# ---------------------------------------------------------------------------
# 4. libtcm (patched)
# ---------------------------------------------------------------------------
log "building libtcm"
HWLOCROOT="$HWLOC_PREFIX" cmake -S "$ONETBB_SRC/thread_composability_manager" -B "$TCM_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DTCM_TEST=OFF -DTCM_STRICT=OFF \
    >"$WORK/libtcm-configure.log" 2>&1
ninja -C "$TCM_BUILD" -j"$JOBS"

# ---------------------------------------------------------------------------
# 5. assemble runtime/
# ---------------------------------------------------------------------------
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"

tbb_real="$(find "$ONETBB_BUILD" -name 'libtbb.so.12.*' -type f | head -n1)"
tcm_real="$(find "$TCM_BUILD" -name 'libtcm.so.1.*' -type f | head -n1)"
[ -n "$tbb_real" ] || { log "error: libtbb.so.12.* not found" >&2; exit 1; }
[ -n "$tcm_real" ] || { log "error: libtcm.so.1.* not found" >&2; exit 1; }

cp -a "$tbb_real" "$RUNTIME/"
cp -a "$tcm_real" "$RUNTIME/"
( cd "$RUNTIME" && ln -sf "$(basename "$tbb_real")" libtbb.so.12 )
( cd "$RUNTIME" && ln -sf "$(basename "$tcm_real")" libtcm.so.1 )

hwloc_lib="$(find_hwloc_lib)"
hwloc_real="$(readlink -f "$hwloc_lib")"
cp -a "$hwloc_real" "$RUNTIME/$(basename "$hwloc_real")"
( cd "$RUNTIME" && ln -sf "$(basename "$hwloc_real")" libhwloc.so.15 )

# Keep the matching oneTBB headers with the libraries so that
# build-reproducers.sh does not need the full .work/ source tree.
rm -rf "$RUNTIME/include"
cp -a "$ONETBB_SRC/include" "$RUNTIME/include"

log "runtime libraries:"
ls -l "$RUNTIME" >&2
log "done.  Run scripts/build-reproducers.sh next."
