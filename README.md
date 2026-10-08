# Minimal reproducer: exit-time SIGSEGV in oneTBB's libtcm destructor

Reproducer for [VilmaLab/apitofsim#84](https://github.com/VilmaLab/apitofsim/issues/84)
(intended upstream target: [uxlfoundation/oneTBB](https://github.com/uxlfoundation/oneTBB)).

A process that ran a oneTBB `parallel_for` exits with SIGSEGV.  The main thread
is executing libtcm's exit-time destructor while a oneTBB worker thread is
calling `dlclose(libtcm)` from `tbb::detail::r1::dynamic_unlink_all()`.  The
worker unmaps libtcm out from under the main thread, which then faults on the
next instruction inside the destructor.

Everything here is a self-contained copy; apitofsim is not modified.  See
[`notes/reduction-from-apitofsim.md`](notes/reduction-from-apitofsim.md) for
how the original Python test suite was reduced to the two programs below.

## Two reproducers

| Reproducer | Form | Notes |
| --- | --- | --- |
| `standalone/main` + `standalone/libwork.so` | plain C host + C++ `dlopen`ed library | no Python at all |
| `python/mesh_exit.py` + `python/apitoflite*.so` | Python module | native CPython C API, **no nanobind**, no Eigen/NumPy |

`standalone/main-linked` is a control variant (oneTBB as a `DT_NEEDED`
dependency) that does **not** crash; see below.

## Quick start

Requirements: a C/C++ toolchain, CMake, Ninja, `git`, `curl`, Python 3 headers,
and a `libhwloc.so.15` available on the system (the build script only needs
hwloc *headers*, which it downloads and configures if necessary).

```sh
make onetbb        # clone + patch + build oneTBB into ./runtime (optional)
make run RUNS=5    # build the reproducers and run each one 5 times
```

`make run` builds oneTBB automatically if `./runtime` is missing, so the first
command is only needed to force a rebuild.  `runtime/` holds the patched
`libtbb.so.12`, `libtcm.so.1`, a `libhwloc.so.15` and the matching oneTBB
headers; nothing is installed system-wide.

`make run` should print something like:

```text
PASS  standalone (dlopen oneTBB)               5/5 exit=139
PASS  standalone control (DT_NEEDED oneTBB)    5/5 exit=0
PASS  standalone with LD_PRELOAD=libtcm.so.1   5/5 exit=0
PASS  python -X dev mesh_exit.py               5/5 exit=139
```

Run the reproducers by hand:

```sh
export LD_LIBRARY_PATH="$PWD/runtime"
./standalone/main                                  # SIGSEGV at exit
PYTHONPATH="$PWD/python" python3 -X dev python/mesh_exit.py  # SIGSEGV at exit
```

Both print `work done` / `mesh done` first, then die during process exit with
signal 11.  `python -X dev` is not required; it matches the issue's setup.

## What is patched, and why

`patches/0001-tcm-sleep-in-hwloc-topology-destructor.patch` is applied to a
build-local checkout of oneTBB v2023.1.0.  It inserts a 1 s sleep into
`hwloc_topology_loader_t::~hwloc_topology_loader_t()` in
`thread_composability_manager/include/tcm/detail/hwloc_utils.h`, immediately
after `hwloc_topology_destroy(topology)`.

That destructor is tiny, so the window in which the worker's `dlclose` can land
while the main thread is still executing libtcm code is only a few
microseconds.  The sleep widens the window to a second, turning an intermittent
race into a deterministic crash.  It is a diagnostic patch, not a fix.

The bug reproduces without the patch too — with the unpatched Intel oneAPI
redistributable libtcm, `python -X dev mesh_exit.py` failed on attempt 29 of 60
in this environment — but it is rare and not usable as a regression test.

## Root cause

1. When oneTBB is initialised, `tcm_adaptor::initialize()`
   (`src/tbb/tcm_adaptor.cpp`) `dlopen()`s `libtcm.so.1` and the handle is saved
   in the global `handles_t` table (`src/tbb/dynamic_link.cpp`).
2. libtcm has a namespace-scope object
   `hwloc_topology_loader_t topology_loader;`.  Its constructor runs when libtcm
   is loaded and calls `hwloc_topology_load()`; its destructor is registered
   with `__cxa_atexit` and calls `hwloc_topology_destroy()`.
3. At process exit, whichever thread drops the last `__TBB_InitOnce` reference
   runs `governor::release_resources()` → `dynamic_unlink_all()` →
   `dlclose(libtcm)`.  That thread is frequently an `rml::private_worker`
   (`private_server::remove_server_ref` →
   `thread_dispatcher::acknowledge_close_connection` →
   `threading_control::destroy` → `__TBB_InitOnce::remove_ref`).
4. Meanwhile the main thread runs the `__cxa_atexit` destructor of
   `topology_loader`, which is executing code inside libtcm.  If `dlclose`
   reaches link-map refcount 0 during this window, glibc munmaps libtcm and the
   main thread faults on the next instruction.

The upstream report contains exactly this pair of stacks (a worker inside
`dynamic_unlink`/`dlclose` and the main thread inside
`hwloc_topology_loader_t::~hwloc_topology_loader_t`) and a faulting PC at
offset `0x3989`, the instruction after
`call hwloc_topology_destroy@plt`.

### Why the host has to `dlopen` oneTBB

glibc's `_dl_fini()` bumps `l_direct_opencount` for every loaded object before
running its finalisers (`elf/dl-fini.c`: *"Bump l_direct_opencount of all
objects so that they are not dlclose()ed from underneath us"*), and decrements
it afterwards.  So while a DSO's destructor runs from `_dl_fini()`, a
concurrent `dlclose()` cannot unmap it and the race is harmless.

That protection does **not** apply when the destructor is dispatched by
`__run_exit_handlers()`.  Whether `_dl_fini` or `__run_exit_handlers` runs the
destructor depends on when the DSO was loaded relative to the registration of
`_dl_fini`:

* oneTBB linked into the executable (`DT_NEEDED`): libtcm is `dlopen()`ed
  during startup, before `_dl_fini` is registered, so libtcm's destructor runs
  from `_dl_fini` — protected, no crash.  This is the
  `standalone/main-linked` control.
* oneTBB loaded by a `dlopen()`ed object (Python extension, plugin): libtcm is
  `dlopen()`ed after `_dl_fini` was registered, so its destructor runs from
  `__run_exit_handlers` — unprotected, crash.

This is why the bug shows up through a native Python extension and why
`standalone/main` `dlopen()`s `libwork.so` instead of linking oneTBB directly.

### Why `LD_PRELOAD=libtcm.so.1` avoids it

Preloading libtcm leaves an extra loader reference, so oneTBB's `dlclose` can
never bring the refcount to zero and the library is never unmapped.  The issue
reports this workaround; `make run` checks it as a control.

## Evidence

`standalone/main` under gdb (build-local oneTBB with the reproducer patch):

```text
Thread 1 "main_dl" received signal SIGSEGV, Segmentation fault.
0x00007ffff7fa20d0 in ?? ()
=> 0x00007ffff7fa20d0:	Cannot access memory at address 0x7ffff7fa20d0
```

`libtcm` is unmapped by then, so gdb cannot resolve the address.  Subtracting
the load base (`0x7ffff7fa0000`, obtained from the loader logs) gives offset
`0x20d0` in `libtcm.so.1.5.0`, inside
`hwloc_topology_loader_t::~hwloc_topology_loader_t`:

```text
20b4: call hwloc_topology_destroy@plt
20cb: call nanosleep@plt        <- 1 s window added by the reproducer patch
20d0: cmp  $0xffffffff,%eax     <- faulting PC: fetched from unmapped libtcm
20d5: movb $0x0,0x0(%rbp)       <- first write to libtcm after the window
```

Without the 1 s window the fault lands directly on `20d5`, i.e. on the first
instruction after `call hwloc_topology_destroy@plt` — the same shape as the
`0x3989` PC in the upstream report.

## Layout

```text
patches/0001-tcm-sleep-in-hwloc-topology-destructor.patch
scripts/build-onetbb.sh        clone/patch/build oneTBB -> ./runtime
scripts/build-reproducers.sh   build both reproducers
scripts/run.sh                 run everything N times
standalone/main.c              host: dlopen() oneTBB-using library
standalone/work.cpp            dlopen()ed library: apitofsim-style parallel_for
standalone/main-linked.cpp     control: oneTBB as DT_NEEDED (does not crash)
python/apitoflite.cpp          native CPython C API extension (no nanobind)
python/mesh_exit.py            the reduced apitofsim reproducer
notes/reduction-from-apitofsim.md
```

## Validation performed

* Fedora 44, glibc 2.43, GCC 16.2.1, oneTBB v2023.1.0, TCM 1.5.0, Python 3.14.7.
* Build-local patched oneTBB (libtbb + libtcm):
  * `standalone/main`: 5/5 SIGSEGV.
  * `python -X dev mesh_exit.py`: 5/5 SIGSEGV.
  * `standalone/main-linked`: 3/3 exit 0.
  * `standalone/main` with `LD_PRELOAD=libtcm.so.1`: 3/3 exit 0.
* Patched libtcm against the **unpatched** Intel oneAPI redistributable
  `libtbb.so.12`: both reproducers SIGSEGV 3/3, confirming the failure comes
  from the oneTBB/TCM/libhwloc shutdown ordering rather than from the
  build-local libtbb.
* Unpatched redistributable libtcm + redistributable libtbb:
  `python -X dev mesh_exit.py` crashed 1/60; `standalone/main` crashed 0/60.

## Notes for an upstream fix

The reproducer does not depend on the mesh arithmetic, Eigen, nanobind, Python,
DuckDB, PyArrow, or pytest — only on oneTBB lazily loading libtcm (and, through
it, libhwloc) and then unloading it from a worker thread during process exit.
Candidate directions, none implemented here:

* do not `dlclose` dynamically loaded runtimes at shutdown (or load them into a
  non-unloadable scope), and/or
* finish joining workers before `dynamic_unlink_all()`, and/or
* make the TCM destructor's dependency on the worker shutdown explicit instead
  of relying on glibc exit-handler ordering.
