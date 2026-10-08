/* Control variant: identical work, but oneTBB is linked into the executable
 * as a DT_NEEDED dependency instead of being dlopen()ed.
 *
 * In this configuration libtcm is dlopen()ed by oneTBB during process startup,
 * before glibc registers _dl_fini().  At exit libtcm's destructor therefore
 * runs from _dl_fini(), which bumps l_direct_opencount so the worker's
 * dlclose(libtcm) cannot unmap it.  Result: no crash, even with the
 * reproducer patch applied.
 *
 * This is what makes the bug specific to "oneTBB loaded from a dlopen()ed
 * module" (native Python extension, plugin, ...) rather than to plain
 * executables linked against oneTBB.
 */

#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_for.h>

#include <cmath>
#include <cstdio>
#include <vector>

int main() {
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

    std::printf("work done\n");
    std::fflush(stdout);
    return 0;
}
