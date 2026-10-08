// Reduced from apitofsim (VilmaLab/apitofsim, commit 3c46912) --
// src/densityandrate.cpp: compute_mesh_rearranged_presqrt_tbb().
//
// This is the *dlopen()ed* library.  It is deliberately not linked into the
// host executable: oneTBB must be pulled in after the process has started so
// that libtcm is dlopen()ed after glibc has registered _dl_fini().  See the
// README for why that matters.
//
// The arithmetic is irrelevant to the bug; only the two oneTBB parallel_for
// calls matter.

#include <cmath>
#include <cstddef>
#include <vector>

#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_for.h>

extern "C" void run_work() {
    constexpr double bin_width = 1.0;
    constexpr int m_max_rate = 1000;

    std::vector<double> rot_energy_sqrts(m_max_rate);
    oneapi::tbb::parallel_for(
        oneapi::tbb::blocked_range<int>(0, m_max_rate),
        [&](const oneapi::tbb::blocked_range<int>& range) {
            for (int i = range.begin(); i != range.end(); ++i)
                rot_energy_sqrts[i] = std::sqrt(bin_width * (i + 0.5));
        });

    std::vector<double> mesh(m_max_rate);
    oneapi::tbb::parallel_for(
        oneapi::tbb::blocked_range<int>(0, m_max_rate),
        [&](const oneapi::tbb::blocked_range<int>& range) {
            for (int i_p_j = range.begin(); i_p_j != range.end(); ++i_p_j) {
                double mesh_i_p_j = 0;
                for (int j = 0; j < i_p_j; ++j) {
                    int i = i_p_j - j;
                    mesh_i_p_j += (bin_width * (j + 0.5)) * rot_energy_sqrts[i];
                }
                mesh[i_p_j] = mesh_i_p_j;
            }
        });
}
