#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <vector>
#include <unistd.h>
#include <errno.h>

struct Region {
    char* buf;
    size_t bytes;
};

// Zipfian distribution generator
class ZipfianGenerator {
private:
    size_t n_;           // number of items
    double theta_;       // skewness parameter (0 < theta < 1)
    double alpha_;       // = 1 / (1 - theta)
    double zetan_;       // normalization constant
    double eta_;         // helper for generation
    std::mt19937_64 rng_;
    std::uniform_real_distribution<double> uniform_;

    double zeta(size_t n, double theta) {
        double sum = 0.0;
        for (size_t i = 1; i <= n; i++) {
            sum += 1.0 / std::pow(static_cast<double>(i), theta);
        }
        return sum;
    }

public:
    ZipfianGenerator(size_t n, double theta, uint64_t seed = 42)
        : n_(n), theta_(theta), rng_(seed), uniform_(0.0, 1.0) {
        alpha_ = 1.0 / (1.0 - theta_);
        zetan_ = zeta(n_, theta_);
        eta_ = (1.0 - std::pow(2.0 / static_cast<double>(n_), 1.0 - theta_)) / (1.0 - zeta(2, theta_) / zetan_);
    }

    size_t next() {
        double u = uniform_(rng_);
        double uz = u * zetan_;
        if (uz < 1.0) return 0;
        if (uz < 1.0 + std::pow(0.5, theta_)) return 1;
        size_t rank = static_cast<size_t>(static_cast<double>(n_) * std::pow(eta_ * u - eta_ + 1.0, alpha_));
        return std::min(rank, n_ - 1);
    }
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

static void* mmap_aligned_2mb_at(size_t length, void* hint) {
    size_t pagesz = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    if (pagesz == 0) pagesz = 4096;
    size_t request = length + HUGEPAGE_SIZE;
    void* base = mmap(hint, request, PROT_READ | PROT_WRITE,
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

// Zipfian access worker function
static void zipfian_worker(const Region& r, size_t num_items, double theta,
                          size_t accesses_per_sec, size_t max_accesses,
                          std::atomic<bool>& stop_flag, int thread_id,
                          std::atomic<long long>& completion_time_us,
                          std::atomic<int>* active_threads = nullptr) {
    ZipfianGenerator zipf(num_items, theta, 42 + thread_id);  // Different seed per thread
    size_t item_size = r.bytes / num_items;
    if (item_size == 0) item_size = 64;  // minimum item size

    auto start = std::chrono::steady_clock::now();
    size_t total_accesses = 0;

    while (!stop_flag.load(std::memory_order_relaxed) &&
           (max_accesses == 0 || total_accesses < max_accesses)) {
        size_t idx = zipf.next();
        size_t offset = idx * item_size;
        if (offset < r.bytes) {
            volatile char* p = r.buf + offset;
            *p = (*p) + 1;  // Read-modify-write access
        }
        total_accesses++;

        // Rate limiting
        if (accesses_per_sec > 0 && total_accesses % 1000 == 0) {
            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - start).count();
            auto expected_us = (total_accesses * 1000000ULL) / accesses_per_sec;
            if (elapsed < static_cast<long long>(expected_us)) {
                std::this_thread::sleep_for(std::chrono::microseconds(expected_us - elapsed));
            }
        }
    }

    // Record completion time
    auto end = std::chrono::steady_clock::now();
    long long elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    long long expected = 0;
    // Only update if this thread took longer (max across all threads)
    while (elapsed_us > (expected = completion_time_us.load(std::memory_order_relaxed))) {
        if (completion_time_us.compare_exchange_weak(expected, elapsed_us, std::memory_order_relaxed)) {
            break;
        }
    }

    if (active_threads) {
        active_threads->fetch_sub(1, std::memory_order_relaxed);
    }
}

// Phase access worker function for multi-threaded phase access (concurrent on same region)
static void phase_worker(const std::vector<Region>& regions, size_t stride, int iters,
                        std::atomic<int>& current_region, std::atomic<bool>& done_flag,
                        std::atomic<int>& barrier_count, int total_threads) {
    while (!done_flag.load(std::memory_order_relaxed)) {
        int r = current_region.load(std::memory_order_relaxed);
        if (r < 0 || r >= static_cast<int>(regions.size())) break;

        // Work on current region
        for (int i = 0; i < iters; i++) {
            touch_region(regions[r], stride);
        }

        // Barrier: wait for all threads to finish this region
        int arrived = barrier_count.fetch_add(1, std::memory_order_acq_rel) + 1;
        if (arrived == total_threads) {
            // Last thread resets barrier
            barrier_count.store(0, std::memory_order_release);
        } else {
            // Wait for barrier reset
            while (barrier_count.load(std::memory_order_acquire) != 0 &&
                   !done_flag.load(std::memory_order_relaxed)) {
                std::this_thread::yield();
            }
        }
    }
}


static bool allocate_zipf_mem(Region& r, size_t region_mb, void* hint_addr) {
    size_t zipf_bytes = region_mb * 1024UL * 1024UL;
    size_t zipf_rounded = round_up_huge(zipf_bytes);

    if (use_hugetlb_env()) {
        int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB;
#ifdef MAP_HUGE_2MB
        flags |= MAP_HUGE_2MB;
#endif
        r.buf = static_cast<char*>(mmap(hint_addr, zipf_rounded, PROT_READ | PROT_WRITE, flags, -1, 0));
        if (r.buf == MAP_FAILED) {
            perror("mmap MAP_HUGETLB for zipfian region");
            return false;
        }
    } else {
        r.buf = static_cast<char*>(mmap_aligned_2mb_at(zipf_rounded, hint_addr));
        if (r.buf == MAP_FAILED) {
            std::cerr << "alloc failed for zipfian region via mmap_aligned_2mb" << std::endl;
            return false;
        }
        if (madvise(r.buf, zipf_rounded, MADV_HUGEPAGE) != 0) {
            std::cerr << "madvise(MADV_HUGEPAGE) failed for zipfian: " << strerror(errno) << "\n";
        }
    }
    r.bytes = zipf_rounded;
    return true;
}

// Manager thread to handle the lifecycle of the Zipfian workload
// This allows the Zipfian phase to repeat multiple times with sleep intervals,
// independent of the main sequential workload (although it stops if main stops).
// It manages memory allocation/deallocation if unmap_sleep is true.
static void zipf_manager_thread(Region* r, size_t zipf_region_mb, void* hint_addr,
                                size_t zipf_item_size, double zipf_theta,
                                size_t zipf_accesses_per_sec, size_t zipf_workload_size,
                                int zipf_threads, int zipf_repeats, int zipf_sleep_sec,
                                bool zipf_unmap_sleep, std::atomic<bool>* main_stop_flag,
                                std::atomic<long long>* completion_time_us) {

    std::atomic<int> active_threads{0};

    // run is 0-indexed count of repeats. 0 to zipf_repeats inclusive.
    // If repeats=0, runs once (run 0).
    // If repeats=1, runs twice (run 0, run 1).
    for (int run = 0; run <= zipf_repeats; run++) {
        // Check if main thread asked to stop (e.g. sequential phase finished)
        if (main_stop_flag->load(std::memory_order_relaxed)) break;

        // Ensure memory is allocated.
        // For the first run, main() likely allocated it.
        // For subsequent runs, if unmap_sleep is true, we re-allocate here.
        if (r->buf == nullptr) {
             if (!allocate_zipf_mem(*r, zipf_region_mb, hint_addr)) {
                 std::cerr << "Failed to allocate zipf memory for run " << run << std::endl;
                 break;
             }
             // Prefault to avoid page faults during measurement
             size_t page_stride = static_cast<size_t>(sysconf(_SC_PAGESIZE));
             if (page_stride == 0) page_stride = 4096;
             touch_region(*r, page_stride);
             if (run > 0) std::cout << "Re-allocated zipf region for run " << run << ": " << (void*)r->buf << std::endl;
        }

        size_t zipf_num_items = r->bytes / zipf_item_size;
        if (zipf_num_items == 0) zipf_num_items = 1;

        if (run > 0) std::cout << "Starting Zipfian Run " << run << std::endl;

        std::vector<std::thread*> threads;
        std::atomic<bool> local_stop{false};
        std::atomic<long long> run_max_us{0};

        size_t per_thread_accesses = zipf_workload_size;
        if (zipf_workload_size > 0 && zipf_threads > 1) {
            per_thread_accesses = zipf_workload_size / zipf_threads;
        }

        active_threads.store(zipf_threads);
        for (int t = 0; t < zipf_threads; t++) {
            // Pass active_threads counter so workers decrement it upon completion
            // Pass run_max_us to track duration of this specific run
            threads.push_back(new std::thread(zipfian_worker, std::ref(*r),
                                                       zipf_num_items, zipf_theta, zipf_accesses_per_sec,
                                                       per_thread_accesses,
                                                       std::ref(local_stop), t,
                                                       std::ref(run_max_us),
                                                       &active_threads));
        }

        // Wait for workers to finish
        // We poll active_threads instead of joining immediately so we can respond to main_stop_flag
        while (active_threads.load(std::memory_order_relaxed) > 0) {
             if (main_stop_flag->load(std::memory_order_relaxed)) {
                 local_stop.store(true); // Signal workers to stop early
             }
             std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        for (auto* t : threads) {
            t->join();
            delete t;
        }

        long long current_run_time = run_max_us.load();
        std::cout << "Zipfian Run " << run << " Time: " << (current_run_time / 1000.0) << " ms" << std::endl;
        completion_time_us->fetch_add(current_run_time, std::memory_order_relaxed);

        // Between repeats (if not the last one and not stopped)
        if (run < zipf_repeats && !main_stop_flag->load(std::memory_order_relaxed)) {
            if (zipf_unmap_sleep) {
                // Free memory to simulate "cold" start or memory pressure release
                munmap(r->buf, r->bytes);
                r->buf = nullptr;
                // We keep r->bytes non-zero or calculate it again in allocate_zipf_mem
            }
            std::cout << "Zipfian Run " << run << " finished. Sleeping " << zipf_sleep_sec << "s..." << std::endl;

            // Sleep in small chunks to remain responsive to main_stop_flag
            for (int s = 0; s < zipf_sleep_sec * 10; s++) {
                if (main_stop_flag->load(std::memory_order_relaxed)) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
    }
}

int main(int argc, char** argv) {
    size_t num_regions = 2;    // A/B by default
    size_t region_mb = 1024;   // 1 GB per region
    size_t stride = 4096;      // 4 KB stride to tick accessed bit
    int phase_iters = 4;       // sweeps per phase
    int cycles = 8;            // number of region cycles

    // Zipfian parameters (optional)
    size_t zipf_region_mb = 0;        // 0 = disabled
    size_t zipf_item_size = 4096;     // size of each item in bytes (default 4KB)
    double zipf_theta = 0.99;         // skewness parameter (0.99 = highly skewed)
    size_t zipf_accesses_per_sec = 0; // 0 = unlimited
    size_t zipf_workload_size = 0;    // total accesses to perform (0 = unlimited, runs until sequential done)

    // Threading parameters
    int phase_threads = 1;            // number of threads for phase access
    int zipf_threads = 1;             // number of threads for zipfian access

    // New parameters
    int zipf_repeats = 0;
    int zipf_sleep_sec = 0;
    bool zipf_unmap_sleep = false;

    if (argc > 1) num_regions = std::strtoul(argv[1], nullptr, 0);
    if (argc > 2) region_mb = std::strtoul(argv[2], nullptr, 0);
    if (argc > 3) stride = std::strtoul(argv[3], nullptr, 0);
    if (argc > 4) phase_iters = std::atoi(argv[4]);
    if (argc > 5) cycles = std::atoi(argv[5]);
    if (argc > 6) zipf_region_mb = std::strtoul(argv[6], nullptr, 0);
    if (argc > 7) zipf_item_size = std::strtoul(argv[7], nullptr, 0);
    if (argc > 8) zipf_theta = std::strtod(argv[8], nullptr);
    if (argc > 9) zipf_accesses_per_sec = std::strtoul(argv[9], nullptr, 0);
    if (argc > 10) zipf_workload_size = std::strtoul(argv[10], nullptr, 0);
    if (argc > 11) phase_threads = std::atoi(argv[11]);
    if (argc > 12) zipf_threads = std::atoi(argv[12]);
    if (argc > 13) zipf_repeats = std::atoi(argv[13]);
    if (argc > 14) zipf_sleep_sec = std::atoi(argv[14]);
    if (argc > 15) zipf_unmap_sleep = (std::atoi(argv[15]) != 0);

    if (stride == 0) stride = 4096;
    if (zipf_item_size == 0) zipf_item_size = 4096;
    if (phase_threads < 1) phase_threads = 1;
    if (zipf_threads < 1) zipf_threads = 1;

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
              << " cycles=" << cycles << " phase_threads=" << phase_threads;
    if (zipf_region_mb > 0) {
        std::cout << " zipf_region=" << zipf_region_mb << "MB zipf_item_size=" << zipf_item_size << "B"
                  << " zipf_theta=" << zipf_theta << " zipf_rate=" << zipf_accesses_per_sec << "/s"
                  << " zipf_workload=" << zipf_workload_size << " zipf_threads=" << zipf_threads
                  << " zipf_repeats=" << zipf_repeats << " zipf_sleep=" << zipf_sleep_sec << "s"
                  << " zipf_unmap=" << zipf_unmap_sleep;
    }
    std::cout << "\n";

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

    // Setup zipfian region and threads if requested
    Region zipf_region{nullptr, 0};
    std::atomic<bool> zipf_stop_flag{false};
    std::atomic<long long> zipf_completion_time_us{0};
    std::thread* zipf_manager = nullptr;

    if (zipf_region_mb > 0) {
        // Calculate hint address to be 512MB after the last sequential region
        void* hint_addr = nullptr;
        if (!regions.empty()) {
            const size_t GUARD_SIZE = 512UL * 1024UL * 1024UL; // 512 MB guard space
            uintptr_t last_region_end = reinterpret_cast<uintptr_t>(regions.back().buf) + regions.back().bytes;
            hint_addr = reinterpret_cast<void*>(last_region_end + GUARD_SIZE);
        }

        // Allocate zipfian region with hint address
        if (!allocate_zipf_mem(zipf_region, zipf_region_mb, hint_addr)) {
            return 1;
        }

        std::cout << "zipfian region addr=" << static_cast<void*>(zipf_region.buf)
                  << " aligned_2M=" << ((reinterpret_cast<uintptr_t>(zipf_region.buf) % HUGEPAGE_SIZE == 0) ? "yes" : "no")
                  << " bytes=" << zipf_region.bytes << std::endl;

        // Prefault zipfian region
        touch_region(zipf_region, page_stride);

        // Calculate number of items from region size and item size
        size_t zipf_num_items = zipf_region.bytes / zipf_item_size;
        if (zipf_num_items == 0) zipf_num_items = 1;  // minimum 1 item

        std::cout << "Starting zipfian manager thread (threads=" << zipf_threads
                  << ", items=" << zipf_num_items
                  << ", workload=" << zipf_workload_size
                  << ", repeats=" << zipf_repeats
                  << ", sleep=" << zipf_sleep_sec << "s"
                  << (zipf_unmap_sleep ? ", unmap" : "") << ")" << std::endl;

        zipf_manager = new std::thread(zipf_manager_thread, &zipf_region, zipf_region_mb, hint_addr,
                                       zipf_item_size, zipf_theta, zipf_accesses_per_sec, zipf_workload_size,
                                       zipf_threads, zipf_repeats, zipf_sleep_sec, zipf_unmap_sleep,
                                       &zipf_stop_flag, &zipf_completion_time_us);
    }

    // Print memory region header
    std::cout << "\n========== MEMORY REGIONS ==========\n";
    if (!regions.empty()) {
        std::cout << "Sequential Phase Zone (" << regions.size() << " regions):\n";
        uintptr_t phase_start = reinterpret_cast<uintptr_t>(regions[0].buf);
        uintptr_t phase_end = phase_start + regions[0].bytes - 1;

        for (size_t i = 1; i < regions.size(); i++) {
            uintptr_t region_start = reinterpret_cast<uintptr_t>(regions[i].buf);
            uintptr_t region_end = region_start + regions[i].bytes - 1;

            if (region_start < phase_start) {
                phase_start = region_start;
            }
            if (region_end > phase_end) {
                phase_end = region_end;
            }
        }
        std::cout << "  Start: 0x" << std::hex << phase_start << std::dec << "\n";
        std::cout << "  End:   0x" << std::hex << phase_end << std::dec << "\n";
    }
    if (zipf_region.buf) {
        std::cout << "Zipfian Zone:\n";
        uintptr_t zipf_start = reinterpret_cast<uintptr_t>(zipf_region.buf);
        uintptr_t zipf_end = zipf_start + zipf_region.bytes - 1;
        std::cout << "  Start: 0x" << std::hex << zipf_start << std::dec << "\n";
        std::cout << "  End:   0x" << std::hex << zipf_end << std::dec << "\n";
    }
    std::cout << "====================================\n\n";

    std::cerr << "===ROI_START===" << std::endl;

    // Setup phase worker threads if using multi-threading
    std::vector<std::thread*> phase_thread_pool;
    std::atomic<int> current_region{0};
    std::atomic<bool> phase_done{false};
    std::atomic<int> barrier_count{0};

    if (phase_threads > 1) {
        std::cout << "Starting " << phase_threads << " phase worker thread(s)" << std::endl;
        for (int t = 0; t < phase_threads; t++) {
            phase_thread_pool.push_back(new std::thread(phase_worker, std::ref(regions),
                                                        stride, phase_iters,
                                                        std::ref(current_region), std::ref(phase_done),
                                                        std::ref(barrier_count), phase_threads));
        }
    }

    // Start timing for the entire workload
    auto workload_start = std::chrono::high_resolution_clock::now();
    auto sequential_start = workload_start;

    for (int c = 0; c < cycles; c++) {
        std::vector<double> region_ms(regions.size(), 0.0);

        for (size_t r = 0; r < regions.size(); r++) {
            auto start = std::chrono::high_resolution_clock::now();

            if (phase_threads > 1) {
                // Multi-threaded: signal threads to work on region r
                current_region.store(static_cast<int>(r), std::memory_order_release);
                barrier_count.store(0, std::memory_order_release);

                // Wait for all threads to complete
                while (barrier_count.load(std::memory_order_acquire) < phase_threads) {
                    std::this_thread::yield();
                }
            } else {
                // Single-threaded: do work directly
                for (int i = 0; i < phase_iters; i++) {
                    touch_region(regions[r], stride);
                }
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

    // Calculate sequential phase time
    auto sequential_end = std::chrono::high_resolution_clock::now();
    double sequential_time_ms = std::chrono::duration_cast<std::chrono::microseconds>(sequential_end - sequential_start).count() / 1000.0;

    std::cerr << "===ROI_END===" << std::endl;

    // Stop phase worker threads if running
    if (!phase_thread_pool.empty()) {
        std::cout << "Stopping phase worker threads..." << std::endl;
        phase_done.store(true, std::memory_order_relaxed);
        for (auto* t : phase_thread_pool) {
            t->join();
            delete t;
        }
        std::cout << "Phase worker threads stopped" << std::endl;
    }

    // Stop zipfian threads if running
    double zipfian_time_ms = 0.0;
    if (zipf_manager) {
        if (zipf_workload_size == 0) {
            std::cout << "Stopping zipfian manager (unlimited)..." << std::endl;
            zipf_stop_flag.store(true, std::memory_order_relaxed);
        } else {
            std::cout << "Waiting for zipfian manager to complete..." << std::endl;
        }

        zipf_manager->join();
        delete zipf_manager;

        zipfian_time_ms = zipf_completion_time_us.load(std::memory_order_relaxed) / 1000.0;
        std::cout << "Zipfian manager stopped" << std::endl;
    }

    // Report timing summary
    double total_time_ms = sequential_time_ms + zipfian_time_ms;

    std::cout << "\n========== TIMING SUMMARY ==========\n";
    std::cout << "Sequential Phase Time: " << sequential_time_ms << " ms\n";
    if (zipf_region_mb > 0) {
        std::cout << "Zipfian Phase Time:    " << zipfian_time_ms << " ms\n";
    }
    std::cout << "Total Time (Sum):      " << total_time_ms << " ms\n";

    // Cleanup zipfian region
    if (zipf_region.buf) {
        munmap(zipf_region.buf, zipf_region.bytes);
    }

    return 0;
}
