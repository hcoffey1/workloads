#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <random>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <vector>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <fstream>

std::chrono::steady_clock::time_point g_start_time;
std::chrono::steady_clock::time_point g_phase_start_time;

// Function to update Regent's view of a Region
void update_regent_region(int region_id, uint64_t start, uint64_t end) {
    char dir_path[256];
    snprintf(dir_path, sizeof(dir_path), "/tmp/regent/region_%d", region_id);

    char cmd[512];
    snprintf(cmd, sizeof(cmd), "mkdir -p %s", dir_path);
    int ret = system(cmd);
    if (ret != 0) {
        std::cerr << "Failed to create directory: " << dir_path << "\n";
    }

    char bounds_file[256];
    snprintf(bounds_file, sizeof(bounds_file), "%s/bounds", dir_path);

    // Open the bounds file for writing (truncating existing content)
    FILE* f = fopen(bounds_file, "w");
    if (f == NULL) {
        perror("Failed to open Regent bounds file");
        return;
    }

    // Write the new range in Hex format: START-END
    // usage of %lx for unsigned long (uint64_t usually)
    fprintf(f, "%lx-%lx\n", start, end);

    fclose(f);
    printf("Updated Regent Region %d bounds to 0x%lx - 0x%lx\n", region_id, start, end);
}

// Function to log annotation events if REGENT_ANNOTATION_FILE is set
void annotate_event(const std::string& msg) {
    const char* env_path = getenv("REGENT_ANNOTATION_FILE");
    if (!env_path) return;

    std::ofstream outfile;
    outfile.open(env_path, std::ios_base::app); // Append mode
    if (outfile.is_open()) {
        auto now = std::chrono::steady_clock::now();
        std::chrono::duration<double> elapsed = now - g_start_time;

        outfile << std::fixed << std::setprecision(6) << elapsed.count() << " " << msg << "\n";
        outfile.close();
    }
}

// =============================================================================
// DATA STRUCTURES
// =============================================================================

struct Region {
    char* buf;
    size_t bytes;
};

// =============================================================================
// ZIPFIAN GENERATOR
// =============================================================================

class ZipfianGenerator {
private:
    size_t n_;
    double theta_;
    double alpha_;
    double zetan_;
    double eta_;
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

// =============================================================================
// MEMORY ALLOCATION UTILITIES
// =============================================================================

static constexpr size_t HUGEPAGE_SIZE = 2UL * 1024UL * 1024UL;

static bool use_hugetlb_env() {
    const char* v = getenv("USE_HUGETLB");
    if (!v) return false;
    return v[0] != '\0' && v[0] != '0';
}

static size_t round_up_huge(size_t bytes) {
    return (bytes + HUGEPAGE_SIZE - 1) & ~(HUGEPAGE_SIZE - 1);
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
    // size_t head = static_cast<size_t>(aligned - addr);
    // if (head) munmap(reinterpret_cast<void*>(addr), head);
    // size_t tail = (addr + request) - (aligned + length);
    // if (tail) munmap(reinterpret_cast<void*>(aligned + length), tail);
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

// =============================================================================
// WORKER CONFIGURATION
// =============================================================================

struct WorkerConfig {
    double delay_sec;      // Delay before starting (seconds)
    double runtime_sec;    // How long to run (0 = until global stop)
    double phase_duration; // Seconds to spend on each sequential region before moving to next
};

// =============================================================================
// SEQUENTIAL WORKER
// =============================================================================

static void sequential_worker(
    const std::vector<Region>& regions,
    size_t stride,
    const WorkerConfig& config,
    std::atomic<bool>& global_stop,
    std::atomic<uint64_t>& op_counter,
    std::atomic<bool>& worker_done
) {
    using Clock = std::chrono::steady_clock;

    // Initialize RNG
    std::random_device rd;
    std::mt19937 rng(rd());

    // Handle delay
    if (config.delay_sec > 0) {
        auto delay_ms = static_cast<int>(config.delay_sec * 1000);
        auto delay_end = Clock::now() + std::chrono::milliseconds(delay_ms);
        while (Clock::now() < delay_end && !global_stop.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    if (global_stop.load(std::memory_order_relaxed)) {
        worker_done.store(true, std::memory_order_relaxed);
        return;
    }

    auto start_time = Clock::now();
    auto runtime_ms = static_cast<int64_t>(config.runtime_sec * 1000);

    // Time-based phase synchronization:
    // All workers reference g_phase_start_time (set in main before thread launch).
    // Each worker tracks its own phase iteration counter `i`. It advances to
    // the next region when:
    //   (thread_now - g_phase_start_time) > phase_duration * i + phase_duration
    // i.e. (thread_now - g_phase_start_time) > phase_duration * (i + 1)
    size_t phase_iteration = 0;
    size_t num_regions = regions.size();
    size_t region_idx = 0;
    double phase_dur = config.phase_duration;

    while (!global_stop.load(std::memory_order_relaxed)) {
        // Check runtime limit
        if (config.runtime_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start_time).count();
            if (elapsed >= runtime_ms) {
                break;
            }
        }

        // Check if we need to advance to the next region based on elapsed time
        auto now = Clock::now();
        double elapsed_since_phase_start = std::chrono::duration<double>(now - g_phase_start_time).count();
        if (elapsed_since_phase_start > phase_dur * (phase_iteration + 1)) {
            phase_iteration++;
            region_idx = phase_iteration % num_regions;
        }

        // Access the current region
        const auto& region = regions[region_idx];
        volatile char* p = region.buf;
        size_t num_accesses = region.bytes / stride;
        if (num_accesses == 0 && region.bytes > 0) num_accesses = 1;

        if (num_accesses > 0) {
            std::uniform_int_distribution<size_t> dist(0, num_accesses - 1);
            for (size_t i = 0; i < num_accesses; i++) {
                if (global_stop.load(std::memory_order_relaxed)) break;

                // Re-check phase transition periodically within inner loop
                auto inner_now = Clock::now();
                double inner_elapsed = std::chrono::duration<double>(inner_now - g_phase_start_time).count();
                if (inner_elapsed > phase_dur * (phase_iteration + 1)) {
                    phase_iteration++;
                    region_idx = phase_iteration % num_regions;
                    break; // Break out to restart with the new region
                }

                size_t idx = dist(rng);
                size_t offset = idx * stride;
                if (offset < region.bytes) {
                    p[offset]++;
                    op_counter.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }
    }

    worker_done.store(true, std::memory_order_relaxed);
}

// =============================================================================
// ZIPFIAN WORKER
// =============================================================================

static void zipfian_worker(
    const Region& region,
    size_t item_size,
    double theta,
    const WorkerConfig& config,
    std::atomic<bool>& global_stop,
    std::atomic<uint64_t>& op_counter,
    std::atomic<bool>& worker_done,
    int thread_id
) {
    using Clock = std::chrono::steady_clock;

    // Handle delay
    if (config.delay_sec > 0) {
        auto delay_ms = static_cast<int>(config.delay_sec * 1000);
        auto delay_end = Clock::now() + std::chrono::milliseconds(delay_ms);
        while (Clock::now() < delay_end && !global_stop.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    if (global_stop.load(std::memory_order_relaxed)) {
        worker_done.store(true, std::memory_order_relaxed);
        return;
    }

    size_t num_items = region.bytes / item_size;
    if (num_items == 0) num_items = 1;

    ZipfianGenerator zipf(num_items, theta, 42 + thread_id);

    auto start_time = Clock::now();
    auto runtime_ms = static_cast<int64_t>(config.runtime_sec * 1000);

    while (!global_stop.load(std::memory_order_relaxed)) {
        // Check runtime limit
        if (config.runtime_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start_time).count();
            if (elapsed >= runtime_ms) {
                break;
            }
        }

        size_t idx = zipf.next();
        size_t offset = idx * item_size;
        if (offset < region.bytes) {
            volatile char* p = region.buf + offset;
            *p = (*p) + 1;
            op_counter.fetch_add(1, std::memory_order_relaxed);
        }
    }

    worker_done.store(true, std::memory_order_relaxed);
}

// =============================================================================
// USAGE
// =============================================================================

static void print_usage(const char* prog) {
    std::cerr << "Usage: " << prog << " [OPTIONS]\n"
              << "\nGlobal Options:\n"
              << "  --duration <sec>         Total benchmark duration (default: 30)\n"
              << "  --sample-period <ms>     Throughput sampling period in ms (default: 1000)\n"
              << "\nSequential Pattern Options:\n"
              << "  --seq-regions <n>        Number of sequential regions (default: 2)\n"
              << "  --seq-phase-duration <s> Seconds per region before advancing (default: 5.0)\n"
              << "  --seq-region-mb <mb>     Size of each sequential region in MB (default: 1024)\n"
              << "  --seq-stride <bytes>     Access stride in bytes (default: 4096)\n"
              << "  --seq-delay <sec>        Delay before starting sequential (default: 0)\n"
              << "  --seq-runtime <sec>      Runtime for sequential (0 = global duration)\n"
              << "  --seq-threads <n>        Number of sequential threads (default: 1)\n"
              << "\nZipfian Pattern Options:\n"
              << "  --zipf-region-mb <mb>    Size of zipfian region in MB (0 = disabled, default: 0)\n"
              << "  --zipf-item-size <bytes> Item size for zipfian (default: 4096)\n"
              << "  --zipf-theta <0-1>       Zipfian skew parameter (default: 0.99)\n"
              << "  --zipf-delay <sec>       Delay before starting zipfian (default: 0)\n"
              << "  --zipf-runtime <sec>     Runtime for zipfian (0 = global duration)\n"
              << "  --zipf-threads <n>       Number of zipfian threads (default: 1)\n"
              << "\nOutput Format (stdout):\n"
              << "  [DATA], timestamp_sec, seq_ops, zipf_ops, seq_throughput, zipf_throughput\n";
}

// =============================================================================
// MAIN
// =============================================================================

int main(int argc, char** argv) {
    g_start_time = std::chrono::steady_clock::now();

    // --- Defaults ---
    double duration_sec = 30.0;
    int sample_period_ms = 1000;

    // Sequential defaults
    size_t seq_regions = 2;
    size_t seq_region_mb = 1024;
    size_t seq_stride = 4096;
    double seq_delay = 0.0;
    double seq_phase_duration = 5.0;
    double seq_runtime = 0.0;
    int seq_threads = 1;

    // Zipfian defaults
    size_t zipf_region_mb = 0; // 0 = disabled
    size_t zipf_item_size = 4096;
    double zipf_theta = 0.99;
    double zipf_delay = 0.0;
    double zipf_runtime = 0.0;
    int zipf_threads = 1;

    // --- Parse arguments ---
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return 0;
        } else if (arg == "--duration" && i + 1 < argc) {
            duration_sec = std::stod(argv[++i]);
        } else if (arg == "--sample-period" && i + 1 < argc) {
            sample_period_ms = std::stoi(argv[++i]);
        } else if (arg == "--seq-regions" && i + 1 < argc) {
            seq_regions = std::stoul(argv[++i]);
        } else if (arg == "--seq-region-mb" && i + 1 < argc) {
            seq_region_mb = std::stoul(argv[++i]);
        } else if (arg == "--seq-stride" && i + 1 < argc) {
            seq_stride = std::stoul(argv[++i]);
        } else if (arg == "--seq-delay" && i + 1 < argc) {
            seq_delay = std::stod(argv[++i]);
        } else if (arg == "--seq-runtime" && i + 1 < argc) {
            seq_runtime = std::stod(argv[++i]);
        } else if (arg == "--seq-phase-duration" && i + 1 < argc) {
            seq_phase_duration = std::stod(argv[++i]);
        } else if (arg == "--seq-threads" && i + 1 < argc) {
            seq_threads = std::stoi(argv[++i]);
        } else if (arg == "--zipf-region-mb" && i + 1 < argc) {
            zipf_region_mb = std::stoul(argv[++i]);
        } else if (arg == "--zipf-item-size" && i + 1 < argc) {
            zipf_item_size = std::stoul(argv[++i]);
        } else if (arg == "--zipf-theta" && i + 1 < argc) {
            zipf_theta = std::stod(argv[++i]);
        } else if (arg == "--zipf-delay" && i + 1 < argc) {
            zipf_delay = std::stod(argv[++i]);
        } else if (arg == "--zipf-runtime" && i + 1 < argc) {
            zipf_runtime = std::stod(argv[++i]);
        } else if (arg == "--zipf-threads" && i + 1 < argc) {
            zipf_threads = std::stoi(argv[++i]);
        } else {
            std::cerr << "Unknown argument: " << arg << "\n";
            print_usage(argv[0]);
            return 1;
        }
    }

    // --- Validate ---
    if (seq_stride == 0) seq_stride = 4096;
    if (seq_phase_duration <= 0) seq_phase_duration = 5.0;
    if (zipf_item_size == 0) zipf_item_size = 4096;
    if (seq_threads < 1) seq_threads = 1;
    if (zipf_threads < 1) zipf_threads = 1;

    // --- Print Configuration ---
    std::cout << "micro_interference: duration=" << duration_sec << "s"
              << " sample_period=" << sample_period_ms << "ms\n";
    std::cout << "  Sequential: regions=" << seq_regions << " region_mb=" << seq_region_mb
              << " stride=" << seq_stride << " delay=" << seq_delay << "s"
              << " phase_duration=" << seq_phase_duration << "s"
              << " runtime=" << (seq_runtime > 0 ? std::to_string(seq_runtime) + "s" : "global")
              << " threads=" << seq_threads << "\n";
    if (zipf_region_mb > 0) {
        std::cout << "  Zipfian: region_mb=" << zipf_region_mb << " item_size=" << zipf_item_size
                  << " theta=" << zipf_theta << " delay=" << zipf_delay << "s"
                  << " runtime=" << (zipf_runtime > 0 ? std::to_string(zipf_runtime) + "s" : "global")
                  << " threads=" << zipf_threads << "\n";
    } else {
        std::cout << "  Zipfian: disabled\n";
    }

    // --- Allocate Sequential Regions ---
    std::vector<Region> seq_region_vec;
    seq_region_vec.reserve(seq_regions);
    size_t page_stride = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    if (page_stride == 0) page_stride = 4096;

    // --- Allocate All Memory Upfront ---
    size_t seq_bytes = seq_region_mb * 1024UL * 1024UL;
    size_t seq_bytes_aligned = round_up_huge(seq_bytes);
    size_t total_size = seq_bytes_aligned * seq_regions;

    size_t zipf_bytes_aligned = 0;
    size_t buffer_bytes_aligned = 0;
    if (zipf_region_mb > 0) {
        size_t bytes = zipf_region_mb * 1024UL * 1024UL;
        zipf_bytes_aligned = round_up_huge(bytes);
        total_size += zipf_bytes_aligned;

        // 1 GB buffer
        size_t buffer_bytes = 1024UL * 1024UL * 1024UL;
        buffer_bytes_aligned = round_up_huge(buffer_bytes);
        total_size += buffer_bytes_aligned;
    }

    char* global_buf = static_cast<char*>(alloc_region(total_size));
    if (!global_buf) {
        std::cerr << "Failed to allocate total memory region\n";
        return 1;
    }
    annotate_event("Allocated global region");
    std::cout << "Allocated global region: " << (total_size / (1024*1024)) << " MB\n";

    // --- Slice Sequential Regions ---
    char* cursor = global_buf;

    for (size_t i = 0; i < seq_regions; i++) {
        Region r{cursor, seq_bytes_aligned};
        seq_region_vec.push_back(r);
        touch_region(r, page_stride); // Prefault
        cursor += seq_bytes_aligned;
    }
    annotate_event("Touched sequential regions");
    std::cout << "Allocated " << seq_regions << " sequential regions (sliced)\n";

    // --- Slice Zipfian Region ---
    Region zipf_region{nullptr, 0};
    if (zipf_region_mb > 0) {
        // Skip buffer
        cursor += buffer_bytes_aligned;

        zipf_region.buf = cursor;
        zipf_region.bytes = zipf_bytes_aligned;
        cursor += zipf_bytes_aligned;

        touch_region(zipf_region, page_stride); // Prefault
        annotate_event("Touched zipfian region");
        std::cout << "Allocated zipfian region: " << zipf_region_mb << " MB (sliced)\n";
    }

    // --- Print Memory Region Boundaries ---
    std::cout << "\n========== MEMORY REGIONS ==========\n";
    if (!seq_region_vec.empty()) {
        std::cout << "Sequential Zone (" << seq_region_vec.size() << " regions, "
                  << seq_region_mb << " MB each):\n";
        uintptr_t seq_start = reinterpret_cast<uintptr_t>(seq_region_vec[0].buf);
        uintptr_t seq_end = seq_start + seq_region_vec[0].bytes - 1;

        for (size_t i = 1; i < seq_region_vec.size(); i++) {
            uintptr_t region_start = reinterpret_cast<uintptr_t>(seq_region_vec[i].buf);
            uintptr_t region_end = region_start + seq_region_vec[i].bytes - 1;
            if (region_start < seq_start) seq_start = region_start;
            if (region_end > seq_end) seq_end = region_end;
        }
        std::cout << "  Start: 0x" << std::hex << seq_start << std::dec << "\n";
        std::cout << "  End:   0x" << std::hex << seq_end << std::dec << "\n";
        sleep(10);
        update_regent_region(0, seq_start, seq_end);
    }
    if (zipf_region.buf) {
        std::cout << "Zipfian Zone (" << zipf_region_mb << " MB):\n";
        uintptr_t zipf_start = reinterpret_cast<uintptr_t>(zipf_region.buf);
        uintptr_t zipf_end = zipf_start + zipf_region.bytes - 1;
        std::cout << "  Start: 0x" << std::hex << zipf_start << std::dec << "\n";
        std::cout << "  End:   0x" << std::hex << zipf_end << std::dec << "\n";

        // Check REGENT_NUM_REGIONS env var to determine how to split/report regions
        const char* num_regions_env = getenv("REGENT_NUM_REGIONS");
        int num_regent_regions = 3; // Default to current behavior
        if (num_regions_env) {
            num_regent_regions = std::atoi(num_regions_env);
        }

        if (num_regent_regions == 2) {
            // Case 2 Regions: Region 0 (Seq), Region 1 (Entire Zipf)
            update_regent_region(1, zipf_start, zipf_end);
        } else {
            // Case 3 Regions: Region 0 (Seq), Region 1 (First 1.5GB Zipf), Region 2 (Rest Zipf)
            // Region 1: First 1.5GB
            uintptr_t r1_start = zipf_start;
            size_t r1_size = 1 * 1024UL * 1024UL * 1024UL;
            if (r1_size > zipf_region.bytes) r1_size = zipf_region.bytes;
            uintptr_t r1_end = r1_start + r1_size - 1;

            update_regent_region(1, r1_start, r1_end);

            // Region 2: Remainder
            if (zipf_region.bytes > r1_size) {
                uintptr_t r2_start = r1_end + 1;
                uintptr_t r2_end = zipf_end;
                update_regent_region(2, r2_start, r2_end);
            }
        }
    }
    std::cout << "=====================================\n\n";

    // --- Setup atomics ---
    std::atomic<bool> global_stop{false};
    std::atomic<uint64_t> seq_ops{0};
    std::atomic<uint64_t> zipf_ops{0};

    std::vector<std::atomic<bool>> seq_done(seq_threads);
    std::vector<std::atomic<bool>> zipf_done(zipf_threads);
    for (int i = 0; i < seq_threads; i++) seq_done[i].store(false);
    for (int i = 0; i < zipf_threads; i++) zipf_done[i].store(false);

    // --- Set global phase start timestamp (all workers sync to this) ---
    g_phase_start_time = std::chrono::steady_clock::now();

    // --- Launch workers ---
    std::vector<std::thread> threads;

    WorkerConfig seq_config{seq_delay, seq_runtime, seq_phase_duration};
    for (int t = 0; t < seq_threads; t++) {
        threads.emplace_back(sequential_worker,
                             std::ref(seq_region_vec), seq_stride, seq_config,
                             std::ref(global_stop), std::ref(seq_ops), std::ref(seq_done[t]));
    }

    if (zipf_region_mb > 0) {
        WorkerConfig zipf_config{zipf_delay, zipf_runtime, 0};
        for (int t = 0; t < zipf_threads; t++) {
            threads.emplace_back(zipfian_worker,
                                 std::ref(zipf_region), zipf_item_size, zipf_theta, zipf_config,
                                 std::ref(global_stop), std::ref(zipf_ops), std::ref(zipf_done[t]), t);
        }
    }

    // --- Sampling loop ---
    std::cout << "\n[DATA], time_sec, seq_ops, zipf_ops, seq_tput_ops_s, zipf_tput_ops_s\n";
    std::cerr << "===ROI_START===\n";

    auto benchmark_start = std::chrono::steady_clock::now();
    uint64_t last_seq_ops = 0;
    uint64_t last_zipf_ops = 0;
    double last_sample_time = 0.0;

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(sample_period_ms));

        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - benchmark_start).count();

        // Read counters
        uint64_t cur_seq_ops = seq_ops.load(std::memory_order_relaxed);
        uint64_t cur_zipf_ops = zipf_ops.load(std::memory_order_relaxed);

        // Calculate throughput
        double dt = elapsed - last_sample_time;
        double seq_tput = (dt > 0) ? static_cast<double>(cur_seq_ops - last_seq_ops) / dt : 0.0;
        double zipf_tput = (dt > 0) ? static_cast<double>(cur_zipf_ops - last_zipf_ops) / dt : 0.0;

        std::cout << "[DATA], " << std::fixed << std::setprecision(3) << elapsed
                  << ", " << cur_seq_ops << ", " << cur_zipf_ops
                  << ", " << std::setprecision(0) << seq_tput << ", " << zipf_tput << "\n";
        std::cout.flush();

        last_seq_ops = cur_seq_ops;
        last_zipf_ops = cur_zipf_ops;
        last_sample_time = elapsed;

        // Check termination
        if (elapsed >= duration_sec) {
            global_stop.store(true, std::memory_order_relaxed);
            break;
        }

        // Check if all workers with finite runtime are done
        bool all_done = true;
        for (int i = 0; i < seq_threads; i++) {
            if (!seq_done[i].load(std::memory_order_relaxed)) all_done = false;
        }
        for (int i = 0; i < zipf_threads; i++) {
            if (!zipf_done[i].load(std::memory_order_relaxed)) all_done = false;
        }
        if (all_done) {
            global_stop.store(true, std::memory_order_relaxed);
            break;
        }
    }

    std::cerr << "===ROI_END===\n";

    // --- Join threads ---
    for (auto& t : threads) {
        t.join();
    }
    annotate_event("All workers joined");

    // --- Final stats ---
    uint64_t final_seq = seq_ops.load();
    uint64_t final_zipf = zipf_ops.load();
    auto end = std::chrono::steady_clock::now();
    double total_time = std::chrono::duration<double>(end - benchmark_start).count();

    std::cout << "\n========== SUMMARY ==========\n";
    std::cout << "Total Time: " << std::fixed << std::setprecision(3) << total_time << " s\n";
    std::cout << "Sequential Ops: " << final_seq << " (" << static_cast<double>(final_seq) / total_time << " ops/s)\n";
    std::cout << "Zipfian Ops: " << final_zipf << " (" << static_cast<double>(final_zipf) / total_time << " ops/s)\n";
    std::cout << "=============================\n";

    // --- Cleanup ---
    if (global_buf) {
        munmap(global_buf, total_size);
    }
    // for (auto& r : seq_region_vec) {
    //     if (r.buf) munmap(r.buf, r.bytes);
    // }
    // if (zipf_region.buf) {
    //     munmap(zipf_region.buf, zipf_region.bytes);
    // }

    return 0;
}
