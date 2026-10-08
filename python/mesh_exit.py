# Reduced apitofsim exit-time crash reproducer.
#
# This mirrors the reproducer from VilmaLab/apitofsim#84, but imports the
# minimal native extension in this directory instead of the apitofsim
# package.  Expected result with the patched oneTBB: SIGSEGV (return code
# -11 / 139) *after* "mesh done" has been printed.

import apitoflite as r

# 2 == apitofsim's MeshMode.compute_mesh_diagonal_multithreaded.
r.precompute_mesh(1000.0, 1.0, 2)

import time

time.sleep(0.02)
print("mesh done", flush=True)
