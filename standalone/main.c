/* Standalone reproducer for the oneTBB/libTCM exit-time SIGSEGV.
 *
 * The host does not link oneTBB.  It dlopen()s libwork.so (which does link
 * oneTBB) and calls run_work().  It then returns from main and lets the
 * process exit, exactly like a Python interpreter shutting down after
 * importing a native extension.
 *
 * Expected result with the patched oneTBB: SIGSEGV (exit status 139) while
 * the process is exiting, after "work done" has been printed.
 *
 * If libtbb were a DT_NEEDED dependency of this executable instead of being
 * dlopen()ed here, glibc's _dl_fini() would protect libtcm and the crash
 * would not reproduce.  See ../standalone/main-linked.c.
 */

#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char** argv) {
    const char* libpath = (argc > 1) ? argv[1] : "./libwork.so";
    void* handle = dlopen(libpath, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        fprintf(stderr, "dlopen(%s) failed: %s\n", libpath, dlerror());
        return 2;
    }

    void (*run_work)(void) = (void (*)(void))dlsym(handle, "run_work");
    if (!run_work) {
        fprintf(stderr, "dlsym(run_work) failed: %s\n", dlerror());
        return 2;
    }

    run_work();

    printf("work done\n");
    fflush(stdout);

    /* Deliberately do NOT dlclose(handle): Python does not unload extension
     * modules either.  The crash happens during process exit, not during
     * dlclose. */
    return 0;
}
