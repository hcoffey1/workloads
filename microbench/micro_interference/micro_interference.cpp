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
#include <cctype>

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#define CPU_PAUSE() _mm_pause()
#else
#define CPU_PAUSE() std::this_thread::yield()
#endif

std::chrono::steady_clock::time_point g_start_time;
std::chrono::steady_clock::time_point g_phase_start_time;

// Batch clock checks to reduce timer overhead (~20-50ns per Clock::now() call).
// With stride=64 and region_mb=64, the inner loop does ~1M accesses; checking
// every 4096 iterations reduces timer calls from ~1M to ~256 per pass.
static constexpr size_t CLOCK_CHECK_INTERVAL = 4096;

// Cache-line-padded atomics to prevent false sharing between seq_ops, zipf_ops,
// and global_stop which are otherwise stack-allocated adjacently.
struct alignas(64) PaddedAtomicBool { std::atomic<bool> val{false}; };
struct alignas(64) PaddedAtomicU64  { std::atomic<uint64_t> val{0}; };

// Publish the current bounds of a workload region to a file that
// libarms_static.so polls (regent_static.cpp reads
// <bounds_dir>/region_<id>/bounds when its config marks the region's
// bounds as deferred).  Off by default — the kernel/clustering ARMS
// variant doesn't consume these files, and the system("mkdir -p ...")
// call below forks /bin/sh, which under LD_PRELOAD inherits libarms
// and runs a duplicate arms_start_tiering(), corrupting the per-second
// vis CSV writers.  Opt in by setting REGENT_REGION_BOUNDS_DIR.
void update_regent_region(int region_id, uint64_t start, uint64_t end) {
    const char* bounds_dir = getenv("REGENT_REGION_BOUNDS_DIR");
    if (!bounds_dir || bounds_dir[0] == '\0') return;

    char dir_path[256];
    snprintf(dir_path, sizeof(dir_path), "%s/region_%d", bounds_dir, region_id);

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
// COUNT PARSING (decimal suffixes: k=1e3, m=1e6, g=1e9)
// =============================================================================

// Parse a count like "1k", "2m", "4g", "1.5m", or a bare integer "5000".
// Suffixes are decimal and case-insensitive. On any malformed input this
// prints an error and exits, since these come from CLI args.
static uint64_t parse_count(const char* arg) {
    std::string s(arg);
    if (s.empty()) {
        std::cerr << "Invalid count: empty value\n";
        exit(1);
    }
    uint64_t mult = 1;
    char last = static_cast<char>(std::tolower(static_cast<unsigned char>(s.back())));
    if (last == 'k') { mult = 1000ULL; s.pop_back(); }
    else if (last == 'm') { mult = 1000000ULL; s.pop_back(); }
    else if (last == 'g') { mult = 1000000000ULL; s.pop_back(); }
    else if (!std::isdigit(static_cast<unsigned char>(last))) {
        std::cerr << "Invalid count suffix in '" << arg
                  << "' (use k/m/g or a bare integer)\n";
        exit(1);
    }
    if (s.empty()) {
        std::cerr << "Invalid count '" << arg << "': no number before suffix\n";
        exit(1);
    }
    size_t pos = 0;
    double base = 0.0;
    try {
        base = std::stod(s, &pos);
    } catch (...) {
        std::cerr << "Invalid count '" << arg << "'\n";
        exit(1);
    }
    if (pos != s.size() || base < 0.0) {
        std::cerr << "Invalid count '" << arg << "'\n";
        exit(1);
    }
    return static_cast<uint64_t>(base * static_cast<double>(mult));
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
        if (p != MAP_FAILED) {
            return p;
        }
        // MAP_HUGETLB failed; fall back to MADV_HUGEPAGE
        std::cerr << "mmap MAP_HUGETLB failed (" << strerror(errno)
                  << "), falling back to MADV_HUGEPAGE\n";
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
    double time_offset;    // Per-thread stagger: thread_id * time_offset is added to delay
                           // and subtracted from phase elapsed, producing an echo of the
                           // sequential pattern shifted by this amount per thread.
};

// =============================================================================
// SYNC (zone-aggregate lockstep barrier)
// =============================================================================
//
// The two zones (sequential, zipfian) can synchronize round-for-round. A round
// of a zone is `my_n` aggregate accesses by that zone (summed across its
// workers): completed_rounds = floor(zone_aggregate_ops / my_n). Zones advance
// in lockstep: a zone may be at most one round ahead of its partner, then all
// its workers stall (busy-spin) until the partner catches up. See
// docs/adr/0001-zone-aggregate-lockstep-sync.md for why this is zone-level and
// not a per-thread barrier (seq threads start staggered).
struct SyncConfig {
    bool enabled = false;
    uint64_t my_n = 0;        // this zone's accesses per round
    uint64_t partner_n = 0;   // partner zone's accesses per round
};

// Compute the per-worker flush/check cadence. With sync on we shrink it so a
// small `my_n` doesn't overshoot rounds via the default 4096-batch.
static uint64_t sync_check_interval(const SyncConfig& sc, uint64_t default_interval) {
    if (!sc.enabled) return default_interval;
    uint64_t fine = sc.my_n / 16;
    if (fine < 1) fine = 1;
    if (fine > 1024) fine = 1024;
    return fine;
}

// Stall this zone's worker while it is more rounds ahead than the partner.
// `my_ops` must already include this worker's just-flushed accesses. Accumulates
// stalled wall-time into `stall_ns`. Polls `global_stop` so shutdown never hangs.
static inline void sync_barrier_wait(
    const SyncConfig& sc,
    std::atomic<uint64_t>& my_ops,
    std::atomic<uint64_t>& partner_ops,
    std::atomic<bool>& global_stop,
    std::atomic<uint64_t>& stall_ns
) {
    if (!sc.enabled) return;
    uint64_t my_completed = my_ops.load(std::memory_order_relaxed) / sc.my_n;
    uint64_t partner_completed = partner_ops.load(std::memory_order_relaxed) / sc.partner_n;
    if (my_completed <= partner_completed) return;

    auto stall_start = std::chrono::steady_clock::now();
    while (!global_stop.load(std::memory_order_relaxed)) {
        partner_completed = partner_ops.load(std::memory_order_relaxed) / sc.partner_n;
        if (my_completed <= partner_completed) break;
        CPU_PAUSE();
    }
    auto stall_end = std::chrono::steady_clock::now();
    stall_ns.fetch_add(
        static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(stall_end - stall_start).count()),
        std::memory_order_relaxed);
}

// =============================================================================
// SEQUENTIAL WORKER
// =============================================================================

static void sequential_worker(
    const std::vector<Region>& regions,
    size_t stride,
    const WorkerConfig& config,
    std::atomic<bool>& global_stop,
    std::atomic<uint64_t>& op_counter,
    std::atomic<bool>& worker_done,
    int thread_id,
    const SyncConfig& sync,
    std::atomic<uint64_t>& partner_ops,
    std::atomic<uint64_t>& stall_ns
) {
    using Clock = std::chrono::steady_clock;
    const uint64_t check_interval = sync_check_interval(sync, CLOCK_CHECK_INTERVAL);

    // Deterministic RNG seeding for reproducible access patterns across runs
    std::mt19937 rng(42 + thread_id);

    // Per-thread stagger: thread t starts t*time_offset seconds after thread 0
    // and uses an effective phase reference shifted forward by the same amount.
    double thread_offset = static_cast<double>(thread_id) * config.time_offset;

    // Handle delay (includes per-thread stagger offset)
    double effective_delay = config.delay_sec + thread_offset;
    if (effective_delay > 0) {
        auto delay_ms = static_cast<int64_t>(effective_delay * 1000);
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

        // Check if we need to advance to the next region based on elapsed time.
        // Subtracting thread_offset shifts this thread's phase reference forward,
        // so each thread sees its own echo of the sequential pattern.
        auto now = Clock::now();
        double elapsed_since_phase_start = std::chrono::duration<double>(now - g_phase_start_time).count() - thread_offset;
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
            uint64_t local_ops = 0;
            uint64_t since_check = 0;
            for (size_t i = 0; i < num_accesses; i++) {
                if (++since_check >= check_interval) {
                    since_check = 0;
                    if (global_stop.load(std::memory_order_relaxed)) break;

                    // Re-check phase transition periodically within inner loop
                    auto inner_now = Clock::now();
                    double inner_elapsed = std::chrono::duration<double>(inner_now - g_phase_start_time).count() - thread_offset;
                    if (inner_elapsed > phase_dur * (phase_iteration + 1)) {
                        phase_iteration++;
                        region_idx = phase_iteration % num_regions;
                        break; // Break out to restart with the new region
                    }

                    // Flush local ops to shared counter, then honor the sync barrier
                    if (local_ops > 0) {
                        op_counter.fetch_add(local_ops, std::memory_order_relaxed);
                        local_ops = 0;
                    }
                    sync_barrier_wait(sync, op_counter, partner_ops, global_stop, stall_ns);
                }

                size_t idx = dist(rng);
                size_t offset = idx * stride;
                if (offset < region.bytes) {
                    p[offset]++;
                    local_ops++;
                }
            }
            // Flush remaining local ops
            if (local_ops > 0) {
                op_counter.fetch_add(local_ops, std::memory_order_relaxed);
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
    int thread_id,
    const SyncConfig& sync,
    std::atomic<uint64_t>& partner_ops,
    std::atomic<uint64_t>& stall_ns
) {
    using Clock = std::chrono::steady_clock;
    const uint64_t check_interval = sync_check_interval(sync, CLOCK_CHECK_INTERVAL);

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

    uint64_t local_ops = 0;
    uint64_t since_check = 0;

    while (true) {
        if (++since_check >= check_interval) {
            since_check = 0;
            if (global_stop.load(std::memory_order_relaxed)) break;

            // Check runtime limit
            if (config.runtime_sec > 0) {
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start_time).count();
                if (elapsed >= runtime_ms) {
                    break;
                }
            }

            // Flush local ops to shared counter, then honor the sync barrier
            if (local_ops > 0) {
                op_counter.fetch_add(local_ops, std::memory_order_relaxed);
                local_ops = 0;
            }
            sync_barrier_wait(sync, op_counter, partner_ops, global_stop, stall_ns);
        }

        size_t idx = zipf.next();
        size_t offset = idx * item_size;
        if (offset < region.bytes) {
            volatile char* p = region.buf + offset;
            *p = (*p) + 1;
            local_ops++;
        }
    }

    // Flush remaining local ops
    if (local_ops > 0) {
        op_counter.fetch_add(local_ops, std::memory_order_relaxed);
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
              << "  --seq-time-offset <sec>  Per-thread stagger between sequential workers;\n"
              << "                           thread t starts t*offset seconds after thread 0\n"
              << "                           and its phase reference is shifted by the same\n"
              << "                           amount, producing an echo of the sequential pattern\n"
              << "                           (default: 0)\n"
              << "\nZipfian Pattern Options:\n"
              << "  --zipf-region-mb <mb>    Size of zipfian region in MB (0 = disabled, default: 0)\n"
              << "  --zipf-item-size <bytes> Item size for zipfian (default: 4096)\n"
              << "  --zipf-theta <0-1>       Zipfian skew parameter (default: 0.99)\n"
              << "  --zipf-delay <sec>       Delay before starting zipfian (default: 0)\n"
              << "  --zipf-runtime <sec>     Runtime for zipfian (0 = global duration)\n"
              << "  --zipf-threads <n>       Number of zipfian threads (default: 1)\n"
              << "\nSync Options (zone-aggregate lockstep barrier):\n"
              << "  --seq-sync <count>       Sequential zone accesses per round (e.g. 1k, 2m)\n"
              << "  --zipf-sync <count>      Zipfian zone accesses per round (e.g. 1k, 2m)\n"
              << "                           Both must be set together to enable sync. Each\n"
              << "                           zone runs its count of accesses per round; the\n"
              << "                           faster zone stalls at the round boundary until\n"
              << "                           the slower zone catches up. Counts use decimal\n"
              << "                           suffixes k=1e3, m=1e6, g=1e9.\n"
              << "  --sync-rounds <K>        Stop once both zones complete K rounds (fixed\n"
              << "                           work); --duration still applies as a safety cap.\n"
              << "                           Requires --seq-sync/--zipf-sync.\n"
              << "                           Note: sync requires both zones enabled, >=1 thread\n"
              << "                           each, and no per-zone --seq-runtime/--zipf-runtime.\n"
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
    double seq_time_offset = 0.0;

    // Zipfian defaults
    size_t zipf_region_mb = 0; // 0 = disabled
    size_t zipf_item_size = 4096;
    double zipf_theta = 0.99;
    double zipf_delay = 0.0;
    double zipf_runtime = 0.0;
    int zipf_threads = 1;

    // Sync defaults (0 = disabled)
    uint64_t seq_sync_n = 0;
    uint64_t zipf_sync_n = 0;
    bool seq_sync_set = false;
    bool zipf_sync_set = false;
    uint64_t sync_rounds = 0; // 0 = time-based termination

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
        } else if (arg == "--seq-time-offset" && i + 1 < argc) {
            seq_time_offset = std::stod(argv[++i]);
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
        } else if (arg == "--seq-sync" && i + 1 < argc) {
            seq_sync_n = parse_count(argv[++i]);
            seq_sync_set = true;
        } else if (arg == "--zipf-sync" && i + 1 < argc) {
            zipf_sync_n = parse_count(argv[++i]);
            zipf_sync_set = true;
        } else if (arg == "--sync-rounds" && i + 1 < argc) {
            sync_rounds = parse_count(argv[++i]);
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
    if (seq_threads < 0) seq_threads = 0;
    if (zipf_threads < 0) zipf_threads = 0;
    if (seq_time_offset < 0) seq_time_offset = 0.0;

    // --- Validate sync (zone-aggregate lockstep barrier) ---
    // Sync is enabled when both per-zone counts are given. Asymmetric configs are
    // rejected so the barrier never needs live-worker tracking and cannot
    // dead-stall a surviving zone (see docs/adr/0001-...).
    bool sync_enabled = seq_sync_set || zipf_sync_set;
    if (sync_enabled) {
        if (seq_sync_set != zipf_sync_set) {
            std::cerr << "Error: --seq-sync and --zipf-sync must be set together\n";
            return 1;
        }
        if (seq_sync_n == 0 || zipf_sync_n == 0) {
            std::cerr << "Error: sync counts must be > 0\n";
            return 1;
        }
        if (zipf_region_mb == 0) {
            std::cerr << "Error: sync requires the zipfian zone enabled (--zipf-region-mb > 0)\n";
            return 1;
        }
        if (seq_threads < 1 || zipf_threads < 1) {
            std::cerr << "Error: sync requires at least 1 thread per zone "
                         "(--seq-threads >= 1, --zipf-threads >= 1)\n";
            return 1;
        }
        if (seq_runtime != 0.0 || zipf_runtime != 0.0) {
            std::cerr << "Error: sync forbids per-zone runtime "
                         "(--seq-runtime/--zipf-runtime must be 0)\n";
            return 1;
        }
    }
    if (sync_rounds > 0 && !sync_enabled) {
        std::cerr << "Error: --sync-rounds requires --seq-sync and --zipf-sync\n";
        return 1;
    }

    // --- Print Configuration ---
    std::cout << "micro_interference: duration=" << duration_sec << "s"
              << " sample_period=" << sample_period_ms << "ms\n";
    std::cout << "  Sequential: regions=" << seq_regions << " region_mb=" << seq_region_mb
              << " stride=" << seq_stride << " delay=" << seq_delay << "s"
              << " phase_duration=" << seq_phase_duration << "s"
              << " runtime=" << (seq_runtime > 0 ? std::to_string(seq_runtime) + "s" : "global")
              << " threads=" << seq_threads
              << " time_offset=" << seq_time_offset << "s\n";
    if (zipf_region_mb > 0) {
        std::cout << "  Zipfian: region_mb=" << zipf_region_mb << " item_size=" << zipf_item_size
                  << " theta=" << zipf_theta << " delay=" << zipf_delay << "s"
                  << " runtime=" << (zipf_runtime > 0 ? std::to_string(zipf_runtime) + "s" : "global")
                  << " threads=" << zipf_threads << "\n";
    } else {
        std::cout << "  Zipfian: disabled\n";
    }
    if (sync_enabled) {
        std::cout << "  Sync: enabled  seq_sync=" << seq_sync_n
                  << " zipf_sync=" << zipf_sync_n << " accesses/round";
        if (sync_rounds > 0) {
            std::cout << "  stop_after=" << sync_rounds << " rounds (duration as cap)";
        }
        std::cout << "\n";
    } else {
        std::cout << "  Sync: disabled\n";
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

    // --- Setup atomics (cache-line-padded to prevent false sharing) ---
    PaddedAtomicBool global_stop;
    PaddedAtomicU64 seq_ops;
    PaddedAtomicU64 zipf_ops;

    std::vector<PaddedAtomicBool> seq_done(seq_threads);
    std::vector<PaddedAtomicBool> zipf_done(zipf_threads);

    // Per-worker accumulated stall time (ns); reported per zone as the max.
    std::vector<PaddedAtomicU64> seq_stall(seq_threads);
    std::vector<PaddedAtomicU64> zipf_stall(zipf_threads);

    // Per-zone sync params (partner counts swapped).
    SyncConfig seq_sync_cfg{sync_enabled, seq_sync_n, zipf_sync_n};
    SyncConfig zipf_sync_cfg{sync_enabled, zipf_sync_n, seq_sync_n};

    // --- Set global phase start timestamp (all workers sync to this) ---
    g_phase_start_time = std::chrono::steady_clock::now();

    // --- Launch workers ---
    std::vector<std::thread> threads;

    WorkerConfig seq_config{seq_delay, seq_runtime, seq_phase_duration, seq_time_offset};
    for (int t = 0; t < seq_threads; t++) {
        threads.emplace_back(sequential_worker,
                             std::ref(seq_region_vec), seq_stride, seq_config,
                             std::ref(global_stop.val), std::ref(seq_ops.val), std::ref(seq_done[t].val), t,
                             std::cref(seq_sync_cfg), std::ref(zipf_ops.val), std::ref(seq_stall[t].val));
    }

    if (zipf_region_mb > 0) {
        WorkerConfig zipf_config{zipf_delay, zipf_runtime, 0, 0};
        for (int t = 0; t < zipf_threads; t++) {
            threads.emplace_back(zipfian_worker,
                                 std::ref(zipf_region), zipf_item_size, zipf_theta, zipf_config,
                                 std::ref(global_stop.val), std::ref(zipf_ops.val), std::ref(zipf_done[t].val), t,
                                 std::cref(zipf_sync_cfg), std::ref(seq_ops.val), std::ref(zipf_stall[t].val));
        }
    }

    // --- Sampling loop ---
    std::cout << "\n[DATA], time_sec, seq_ops, zipf_ops, seq_tput_ops_s, zipf_tput_ops_s\n";
    std::cerr << "===ROI_START===\n";

    auto benchmark_start = std::chrono::steady_clock::now();
    uint64_t last_seq_ops = 0;
    uint64_t last_zipf_ops = 0;
    double last_sample_time = 0.0;

    // In rounds mode, poll finer than the data-sampling cadence so the measured
    // total runtime isn't quantized to a (possibly large) --sample-period.
    int poll_ms = sample_period_ms;
    if (sync_rounds > 0 && poll_ms > 20) poll_ms = 20;
    const char* term_reason = "duration";

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(poll_ms));

        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - benchmark_start).count();

        // Read counters
        uint64_t cur_seq_ops = seq_ops.val.load(std::memory_order_relaxed);
        uint64_t cur_zipf_ops = zipf_ops.val.load(std::memory_order_relaxed);

        // --- Determine termination (so we can emit a final sample on exit) ---
        bool terminate = false;
        if (elapsed >= duration_sec) {
            terminate = true;
            term_reason = (sync_rounds > 0) ? "duration-cap" : "duration";
        }
        if (!terminate && sync_rounds > 0) {
            uint64_t seq_completed = cur_seq_ops / seq_sync_n;
            uint64_t zipf_completed = cur_zipf_ops / zipf_sync_n;
            if (seq_completed >= sync_rounds && zipf_completed >= sync_rounds) {
                terminate = true;
                term_reason = "rounds";
            }
        }
        if (!terminate) {
            // All workers finished on their own (finite per-zone runtime; not
            // possible while sync is enabled, kept for the non-sync path).
            bool all_done = true;
            for (int i = 0; i < seq_threads; i++) {
                if (!seq_done[i].val.load(std::memory_order_relaxed)) all_done = false;
            }
            for (int i = 0; i < zipf_threads; i++) {
                if (!zipf_done[i].val.load(std::memory_order_relaxed)) all_done = false;
            }
            if (all_done) {
                terminate = true;
                term_reason = "workers-done";
            }
        }

        // --- Emit a [DATA] sample at the sampling cadence, and on termination ---
        bool do_emit = terminate ||
            ((elapsed - last_sample_time) * 1000.0 >= sample_period_ms - 0.5);
        if (do_emit) {
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
        }

        if (terminate) {
            global_stop.val.store(true, std::memory_order_relaxed);
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
    uint64_t final_seq = seq_ops.val.load();
    uint64_t final_zipf = zipf_ops.val.load();
    auto end = std::chrono::steady_clock::now();
    double total_time = std::chrono::duration<double>(end - benchmark_start).count();

    std::cout << "\n========== SUMMARY ==========\n";
    std::cout << "Total Time: " << std::fixed << std::setprecision(3) << total_time << " s\n";
    std::cout << "Sequential Ops: " << final_seq << " (" << static_cast<double>(final_seq) / total_time << " ops/s)\n";
    std::cout << "Zipfian Ops: " << final_zipf << " (" << static_cast<double>(final_zipf) / total_time << " ops/s)\n";
    if (sync_enabled) {
        // Per-zone wall-clock stall = max across that zone's workers (the zone
        // stalls as a unit, so the max approximates the time the zone was blocked).
        uint64_t seq_stall_ns = 0;
        for (int i = 0; i < seq_threads; i++) {
            seq_stall_ns = std::max(seq_stall_ns, seq_stall[i].val.load());
        }
        uint64_t zipf_stall_ns = 0;
        for (int i = 0; i < zipf_threads; i++) {
            zipf_stall_ns = std::max(zipf_stall_ns, zipf_stall[i].val.load());
        }
        uint64_t seq_completed = final_seq / seq_sync_n;
        uint64_t zipf_completed = final_zipf / zipf_sync_n;
        std::cout << "Sync: enabled  seq_sync=" << seq_sync_n
                  << " zipf_sync=" << zipf_sync_n << " accesses/round\n";
        std::cout << "  Terminated by: " << term_reason;
        if (sync_rounds > 0) std::cout << " (target " << sync_rounds << " rounds)";
        std::cout << "\n";
        std::cout << "  Sequential: rounds=" << seq_completed
                  << " stall=" << std::setprecision(3)
                  << static_cast<double>(seq_stall_ns) / 1e9 << " s\n";
        std::cout << "  Zipfian:    rounds=" << zipf_completed
                  << " stall=" << std::setprecision(3)
                  << static_cast<double>(zipf_stall_ns) / 1e9 << " s\n";
    }
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
