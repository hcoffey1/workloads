#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/mman.h>
#include <vector>
#include <unistd.h>
#include <errno.h>

struct Region {
    char* buf;
    size_t bytes;
};

static constexpr size_t HUGEPAGE_SIZE = 2UL * 1024UL * 1024UL;

static size_t round_up_huge(size_t bytes) {
    return (bytes + HUGEPAGE_SIZE - 1) & ~(HUGEPAGE_SIZE - 1);
}

static void* alloc_region(size_t bytes) {
    void* p = nullptr;
    size_t aligned_bytes = round_up_huge(bytes);
    int ret = posix_memalign(&p, HUGEPAGE_SIZE, aligned_bytes);
    if (ret != 0) {
        std::cerr << "alloc failed: " << strerror(ret) << "\n";
        return nullptr;
    }
    madvise(p, aligned_bytes, MADV_HUGEPAGE);
    return p;
}

static void touch_region(const Region& r, size_t stride) {
    volatile char* p = r.buf;
    for (size_t i = 0; i < r.bytes; i += stride) {
        p[i]++;
    }
}

int main(int argc, char** argv) {
    size_t num_regions = 2;    // A/B by default
    size_t region_mb = 1024;   // 1 GB per region
    size_t stride = 4096;      // 4 KB stride to tick accessed bit
    int phase_iters = 4;       // sweeps per phase
    int cycles = 8;            // number of region cycles

    if (argc > 1) num_regions = std::strtoul(argv[1], nullptr, 0);
    if (argc > 2) region_mb = std::strtoul(argv[2], nullptr, 0);
    if (argc > 3) stride = std::strtoul(argv[3], nullptr, 0);
    if (argc > 4) phase_iters = std::atoi(argv[4]);
    if (argc > 5) cycles = std::atoi(argv[5]);

    std::vector<Region> regions;
    regions.reserve(num_regions);
    for (size_t i = 0; i < num_regions; i++) {
        size_t bytes = region_mb * 1024UL * 1024UL;
        size_t rounded = round_up_huge(bytes);
        Region r{static_cast<char*>(alloc_region(bytes)), rounded};
        if (!r.buf) {
            return 1;
        }
        regions.push_back(r);
    }

    std::cout << "phase-toggle: regions=" << num_regions << " size=" << region_mb
              << "MB stride=" << stride << "B phase_iters=" << phase_iters
              << " cycles=" << cycles << "\n";

    for (int c = 0; c < cycles; c++) {
        std::vector<double> region_ms(regions.size(), 0.0);

        for (size_t r = 0; r < regions.size(); r++) {
            auto start = std::chrono::high_resolution_clock::now();
            for (int i = 0; i < phase_iters; i++) {
                touch_region(regions[r], stride);
            }
            auto end = std::chrono::high_resolution_clock::now();
            region_ms[r] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count() / 1000.0;
        }

        std::cout << "cycle " << c << " summary" << std::endl;
        for (size_t r = 0; r < region_ms.size(); r++) {
            std::cout << "  region " << r << ": " << region_ms[r] << " ms" << std::endl;
        }
    }

    return 0;
}
