/* Python reproducer for the oneTBB/libTCM exit-time SIGSEGV.
 *
 * This is a minimal copy of the native extension that apitofsim builds with
 * nanobind, rewritten against the native CPython C API.  It links oneTBB and
 * exposes a single function that runs the same triangular mesh computation as
 * apitofsim's compute_mesh_rearranged_presqrt_tbb() (src/densityandrate.cpp,
 * commit 3c46912).
 *
 * No nanobind, no Eigen, no NumPy, no apitofsim Python package.  The module is
 * imported by CPython via dlopen(), which is what makes the bug reproducible:
 * oneTBB (and therefore libtcm) is loaded after the interpreter has started.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <cmath>
#include <vector>

#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_for.h>

namespace {

// Reduced from apitofsim's compute_mesh_rearranged_presqrt_tbb().
void compute_mesh_rearranged_presqrt_tbb(double bin_width, int m_max_rate,
                                         std::vector<double>& out) {
    std::vector<double> rot_energy_sqrts(m_max_rate);
    oneapi::tbb::parallel_for(
        oneapi::tbb::blocked_range<int>(0, m_max_rate),
        [&](const oneapi::tbb::blocked_range<int>& range) {
            for (int i = range.begin(); i != range.end(); ++i)
                rot_energy_sqrts[i] = std::sqrt(bin_width * (i + 0.5));
        });

    out.assign(m_max_rate, 0.0);
    oneapi::tbb::parallel_for(
        oneapi::tbb::blocked_range<int>(0, m_max_rate),
        [&](const oneapi::tbb::blocked_range<int>& range) {
            for (int i_p_j = range.begin(); i_p_j != range.end(); ++i_p_j) {
                double mesh_i_p_j = 0;
                for (int j = 0; j < i_p_j; ++j) {
                    int i = i_p_j - j;
                    mesh_i_p_j += (bin_width * (j + 0.5)) * rot_energy_sqrts[i];
                }
                out[i_p_j] = mesh_i_p_j;
            }
        });
}

PyObject* precompute_mesh(PyObject*, PyObject* args) {
    double energy_max_rate = 0;
    double bin_width = 0;
    int mesh_mode = 0;
    if (!PyArg_ParseTuple(args, "ddi", &energy_max_rate, &bin_width, &mesh_mode))
        return nullptr;

    const int m_max_rate = static_cast<int>(energy_max_rate / bin_width);

    // apitofsim MeshMode::compute_mesh_diagonal_multithreaded == 2.
    if (mesh_mode != 2) {
        PyErr_SetString(PyExc_ValueError,
                        "only mesh_mode 2 (diagonal multithreaded) is supported");
        return nullptr;
    }

    std::vector<double> mesh;
    compute_mesh_rearranged_presqrt_tbb(bin_width, m_max_rate, mesh);

    // The reduced apitofsim reproducer discards the result.
    Py_RETURN_NONE;
}

PyMethodDef methods[] = {
    {"precompute_mesh", precompute_mesh, METH_VARARGS,
     "Run the multithreaded mesh precomputation."},
    {nullptr, nullptr, 0, nullptr},
};

PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT,
    "apitoflite",
    "Reduced apitofsim native module (native CPython C API, no nanobind).",
    -1,
    methods,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

}  // namespace

PyMODINIT_FUNC PyInit_apitoflite(void) {
    return PyModule_Create(&moduledef);
}
