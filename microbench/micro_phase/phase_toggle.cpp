#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdint>
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

static bool use_hugetlb_env() {
    const char* v = getenv("USE_HUGETLB");
    if (!v) return false;
    return v[0] != '\0' && v[0] != '0';
}

static size_t round_up_huge(size_t bytes) {
    return (bytes + HUGEPAGE_SIZE - 1) & ~(HUGEPAGE_SIZE - 1);
}

static unsigned long long sum_anon_huge_kb() {
    FILE* f = fopen("/proc/self/smaps", "re");
    if (!f) return 0;
    char line[512];
    unsigned long long total = 0, val = 0;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "AnonHugePages: %llu kB", &val) == 1) {
            total += val;
        }
    }
    fclose(f);
    return total;
}

static void* mmap_aligned_2mb(size_t length) {
    size_t pagesz = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    if (pagesz == 0) pagesz = 4096;
    size_t request = length + HUGEPAGE_SIZE;
    void* base = mmap(nullptr, request, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) {
        perror("mmap");
        return MAP_FAILED;
    }
    uintptr_t addr = reinterpret_cast<uintptr_t>(base);
    uintptr_t aligned = (addr + (HUGEPAGE_SIZE - 1)) & ~(HUGEPAGE_SIZE - 1);
    size_t head = static_cast<size_t>(aligned - addr);
    if (head) munmap(reinterpret_cast<void*>(addr), head);
    size_t tail = (addr + request) - (aligned + length);
    if (tail) munmap(reinterpret_cast<void*>(aligned + length), tail);
    return reinterpret_cast<void*>(aligned);
}

static void* alloc_region(size_t bytes) {
    size_t aligned_bytes = round_up_huge(bytes);
    if (use_hugetlb_env()) {
        int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB;
#ifdef MAP_HUGE_2MB
        flags |= MAP_HUGE_2MB;
#endif
        void* p = mmap(nullptr, aligned_bytes, PROT_READ | PROT_WRITE, flags, -1, 0);
        if (p == MAP_FAILED) {
            perror("mmap MAP_HUGETLB");
            return nullptr;
        }
        return p;
    }
    void* p = mmap_aligned_2mb(aligned_bytes);
    if (p == MAP_FAILED) {
        std::cerr << "alloc failed via mmap_aligned_2mb" << std::endl;
        return nullptr;
    }
    if (madvise(p, aligned_bytes, MADV_HUGEPAGE) != 0) {
        std::cerr << "madvise(MADV_HUGEPAGE) failed: " << strerror(errno) << "\n";
    }
    return p;
}

static void touch_region(const Region& r, size_t stride) {
    volatile char* p = r.buf;
    for (size_t i = 0; i < r.bytes; i += stride) {
        p[i]++;
    }
    if (r.bytes > 0) {
        p[r.bytes - 1]++;
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
    if (stride == 0) stride = 4096;

    const bool hugetlb = use_hugetlb_env();

    std::vector<Region> regions;
    regions.reserve(num_regions);
    unsigned long long huge_before_kb = sum_anon_huge_kb();
    size_t total_bytes = 0;
    for (size_t i = 0; i < num_regions; i++) {
        size_t bytes = region_mb * 1024UL * 1024UL;
        size_t rounded = round_up_huge(bytes);
        Region r{static_cast<char*>(alloc_region(bytes)), rounded};
        if (!r.buf) {
            return 1;
        }
        regions.push_back(r);
        total_bytes += r.bytes;
    }
    unsigned long long expected_kb = total_bytes / 1024ULL;

    std::cout << "phase-toggle: regions=" << num_regions << " size=" << region_mb
              << "MB stride=" << stride << "B phase_iters=" << phase_iters
              << " cycles=" << cycles << "\n";

    size_t page_stride = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    if (page_stride == 0) page_stride = 4096;

    for (size_t i = 0; i < regions.size(); i++) {
        auto base = reinterpret_cast<uintptr_t>(regions[i].buf);
        bool aligned = (base % HUGEPAGE_SIZE) == 0;
        std::cout << "region " << i << " addr=" << static_cast<void*>(regions[i].buf)
                  << " aligned_2M=" << (aligned ? "yes" : "no")
                  << " bytes=" << regions[i].bytes << std::endl;
    }

    // Prefault once to trigger THP and validate huge page coverage
    for (const auto& r : regions) {
        touch_region(r, page_stride);
    }

    if (hugetlb) {
        std::cout << "USE_HUGETLB set: using reserved hugetlb pages; AnonHugePages accounting will stay near 0." << std::endl;
    } else {
        const unsigned settle_seconds = 5;
        if (settle_seconds > 0) {
            std::cout << "Waiting " << settle_seconds << "s for khugepaged..." << std::endl;
            sleep(settle_seconds);
        }

        unsigned long long huge_after_kb = sum_anon_huge_kb();
        unsigned long long huge_delta_kb = (huge_after_kb > huge_before_kb)
                               ? (huge_after_kb - huge_before_kb)
                               : 0;
        double coverage = expected_kb ? (huge_delta_kb / static_cast<double>(expected_kb)) : 1.0;

#ifdef MADV_COLLAPSE
        for (const auto& r : regions) {
            if (madvise(r.buf, r.bytes, MADV_COLLAPSE) != 0 && errno != EINVAL && errno != EAGAIN) {
                std::cerr << "madvise(MADV_COLLAPSE) failed: " << strerror(errno) << std::endl;
            }
        }
#endif

        const unsigned max_settle_seconds = 20;
        unsigned waited = 0;
        while (coverage < 0.8 && waited < max_settle_seconds) {
            sleep(1);
            waited++;
            huge_after_kb = sum_anon_huge_kb();
            huge_delta_kb = (huge_after_kb > huge_before_kb)
                                ? (huge_after_kb - huge_before_kb)
                                : 0;
            coverage = expected_kb ? (huge_delta_kb / static_cast<double>(expected_kb)) : 1.0;
        }

        if (coverage < 0.8) {
            std::cerr << "Huge page coverage below 80% after " << waited
                      << "s; THP may be disabled or fragmented." << std::endl;
        } else if (waited > 0) {
            std::cout << "Coverage reached " << (coverage * 100.0) << "% after "
                      << waited << "s of additional settle time." << std::endl;
        }
    }

    std::cerr << "===ROI_START===" << std::endl;

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

        if (!hugetlb) {
            unsigned long long cycle_kb = sum_anon_huge_kb();
            long long cycle_delta_kb = static_cast<long long>(cycle_kb) - static_cast<long long>(huge_before_kb);
            double cycle_cov = expected_kb ? (std::max<long long>(cycle_delta_kb, 0) / static_cast<double>(expected_kb)) : 1.0;
            std::cout << "  AnonHugePages now: " << cycle_kb << " kB (delta "
                      << cycle_delta_kb << " kB, coverage=" << (cycle_cov * 100.0) << "%)" << std::endl;
        }
    }
    std::cerr << "===ROI_END===" << std::endl;

    return 0;
}
