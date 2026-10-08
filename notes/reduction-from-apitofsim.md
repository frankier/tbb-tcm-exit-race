# How apitofsim was reduced to these reproducers

Starting point: `VilmaLab/apitofsim`, commit
`3c469121806d447edcb34eb0fa110910091e69d5` (v0.0.17), the revision named in
[issue #84](https://github.com/VilmaLab/apitofsim/issues/84).  apitofsim itself
was not modified; everything below is a separate copy that lives in this
directory.

The 0.0.17 revision is already close to minimal in the issue's own reduced
form:

```python
import apitofsimraw as r

r.precompute_mesh(1000.0, 1.0, r.MeshMode.compute_mesh_diagonal_multithreaded)

import time
time.sleep(0.02)
print("mesh done", flush=True)
```

`precompute_mesh` is a thin wrapper around
`compute_mesh_rearranged_presqrt_tbb()` in `src/densityandrate.cpp`:

```cpp
Eigen::ArrayXd compute_mesh_rearranged_presqrt_tbb(
    double bin_width, int m_max_rate, OperationContext &operation)
{
  Eigen::ArrayXd rot_energy_sqrts = Eigen::ArrayXd(m_max_rate);
  oneapi::tbb::parallel_for(
    oneapi::tbb::blocked_range<int>(0, m_max_rate),
    [=, &rot_energy_sqrts, &operation](const oneapi::tbb::blocked_range<int> &range)
  {
    for (int i = range.begin(); i != range.end() && operation.checkpoint(); ++i)
      rot_energy_sqrts[i] = sqrt(bin_width * (i + 0.5));
  },
    operation.tbb_context());

  Eigen::ArrayXd mesh = Eigen::ArrayXd(m_max_rate);
  oneapi::tbb::parallel_for(
    oneapi::tbb::blocked_range<int>(0, m_max_rate),
    [=, &mesh, &rot_energy_sqrts, &operation](const oneapi::tbb::blocked_range<int> &range)
  {
    for (int i_p_j = range.begin(); i_p_j != range.end() && operation.checkpoint(); ++i_p_j)
    {
      double mesh_i_p_j = 0;
      for (int j = 0; j < i_p_j; j++)
      {
        int i = i_p_j - j;
        double rotational_energy_sqrt = rot_energy_sqrts[i];
        double translational_energy = bin_width * (j + 0.5);
        mesh_i_p_j += translational_energy * rotational_energy_sqrt;
      }
      mesh[i_p_j] = mesh_i_p_j;
    }
  },
    operation.tbb_context());

  return mesh;
}
```

Reduction steps, each one verified to keep the crash:

1. **Drop the Python package.**  The issue already shows that importing only
   the top-level `apitofsimraw` extension (skipping `apitofsim/__init__.py`,
   CLI, DuckDB, PyArrow, ...) is enough.  The crasher only needs one call.

2. **Drop `.checkpoint()` / `OperationContext`.**  The context only exists so
   that cooperative signal cancellation can cancel the TBB task group.  No
   signal is delivered in the reproducer, so `checkpoint()` always returns
   true.  Removing it leaves two plain `parallel_for` loops.

3. **Drop Eigen.**  The arrays are only used as contiguous `double` storage.
   `std::vector<double>` (or a raw allocation) is equivalent.  The arithmetic
   has no bearing on the crash: the fault is in a static destructor at process
   exit, long after the loops have finished.

4. **Drop the mesh arithmetic.**  The triangular inner loop is what makes
   apitofsim spawn a useful number of TBB workers, but any non-trivial
   `parallel_for` does the same.  The reproducers keep the triangular loop so
   the shape of the workload is recognisable, but nothing would change if it
   were a plain sum.

5. **Drop nanobind.**  `python/apitoflite.cpp` is the same extension written
   directly against the CPython C API (`PyArg_ParseTuple` /
   `PyModule_Create`).  The nanobind machinery only matters for argument
   conversion; it is not involved in the crash.

6. **Drop Python entirely.**  `standalone/` does exactly what CPython does when
   it imports the extension: it `dlopen()`s a shared object that links oneTBB,
   calls one function, and then lets the process exit.  This last step is the
   only one that is not literally a subset of apitofsim, but it demonstrates
   that the Python interpreter is not needed.

The one non-obvious constraint that survives reduction is that oneTBB must be
loaded from a `dlopen()`ed object rather than linked into the main executable
as a `DT_NEEDED` dependency.  That is a property of the *host*, and it is why
the Python extension reproduces the bug at all.  See the "Why the host has to
dlopen oneTBB" section of the README.
