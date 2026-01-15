#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <float.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(__x86_64__) || defined(__aarch64__)
#define cpu_relax() __asm__ __volatile__("pause" ::: "memory")
#else
#define cpu_relax() __asm__ __volatile__("" ::: "memory")
#endif

#define SLOPE_BASELINE 8000.0
#define MAX_HITS_PER_STRIDE 1048576

struct options {
    size_t bytes;
    size_t stride;
    uint64_t duration_ms;
    double slope_per_ms; /* strides per millisecond */
    int threads;
    int prefault;
    int write_mode;
};

struct worker_result {
    uint64_t accesses;
    uint64_t runtime_ns;
    uint64_t sink;
};

struct worker_args {
    uint8_t *buffer;
    size_t bytes;
    size_t stride;
    double slope_per_ms;
    uint64_t duration_ms;
    int write_mode;
    size_t start_offset;
    size_t hits_per_stride;
    struct worker_result *result;
    volatile int *start_flag;
};

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [--bytes N | --size-mb M] [--stride N] [--duration-ms N] [--slope N] [--no-prefault] [--read-only]\n"
            "  --bytes        Total buffer size in bytes (default: 536870912)\n"
            "  --size-mb      Total buffer size in MiB (alternative to --bytes)\n"
            "  --stride       Stride in bytes for sequential touches (default: 4096)\n"
            "  --duration-ms  Runtime in milliseconds (default: 20000)\n"
            "  --threads      Number of worker threads (default: 1)\n"
            "  --slope        Target stride advances per millisecond (default: 8000; smaller values increase reuse before advancing)\n"
            "  --no-prefault  Skip prefaulting the buffer before timing\n"
            "  --read-only    Issue loads instead of store increments\n",
            prog);
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static size_t align_up(size_t value, size_t align)
{
    if (align == 0)
        return value;
    size_t mask = align - 1;
    return (value + mask) & ~mask;
}

static int parse_size(const char *arg, size_t *out)
{
    char *end = NULL;
    errno = 0;
    unsigned long long val = strtoull(arg, &end, 10);
    if (errno || end == arg || *end != '\0')
        return -1;
    *out = (size_t)val;
    return 0;
}

static int parse_double(const char *arg, double *out)
{
    char *end = NULL;
    errno = 0;
    double val = strtod(arg, &end);
    if (errno || end == arg || *end != '\0')
        return -1;
    *out = val;
    return 0;
}

static void prefault_buffer(uint8_t *buf, size_t len, size_t stride)
{
    for (size_t i = 0; i < len; i += stride)
        buf[i] = (uint8_t)(i & 0xff);
}

static void *run_worker(void *arg)
{
    struct worker_args *wa = arg;
    size_t idx = wa->start_offset % wa->bytes;
    uint64_t accesses = 0;
    uint64_t local_sink = 0;

    while (*wa->start_flag == 0)
        cpu_relax();

    uint64_t start = now_ns();
    const uint64_t duration_ns = wa->duration_ms * 1000000ull;
    const size_t hits = wa->hits_per_stride;

    while (1) {
        uint64_t now = now_ns();
        if (now - start >= duration_ns)
            break;

        for (size_t h = 0; h < hits; h++) {
            if (wa->write_mode)
                wa->buffer[idx] += 1;
            else
                local_sink += wa->buffer[idx];

            accesses++;
        }

        idx += wa->stride;
        if (idx >= wa->bytes)
            idx -= wa->bytes;
    }

    wa->result->accesses = accesses;
    wa->result->runtime_ns = now_ns() - start;
    wa->result->sink = local_sink;
    return NULL;
}

int main(int argc, char **argv)
{
    struct options opts = {
        .bytes = 512ull * 1024ull * 1024ull,
        .stride = 4096,
        .duration_ms = 20000,
        .slope_per_ms = 8000.0,
        .threads = 1,
        .prefault = 1,
        .write_mode = 1,
    };

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bytes")) {
            if (i + 1 >= argc || parse_size(argv[++i], &opts.bytes)) {
                usage(argv[0]);
                return 1;
            }
        } else if (!strcmp(argv[i], "--size-mb")) {
            size_t mb = 0;
            if (i + 1 >= argc || parse_size(argv[++i], &mb)) {
                usage(argv[0]);
                return 1;
            }
            opts.bytes = mb * 1024ull * 1024ull;
        } else if (!strcmp(argv[i], "--stride")) {
            if (i + 1 >= argc || parse_size(argv[++i], &opts.stride)) {
                usage(argv[0]);
                return 1;
            }
        } else if (!strcmp(argv[i], "--duration-ms")) {
            size_t dur = 0;
            if (i + 1 >= argc || parse_size(argv[++i], &dur)) {
                usage(argv[0]);
                return 1;
            }
            opts.duration_ms = (uint64_t)dur;
        } else if (!strcmp(argv[i], "--threads")) {
            size_t th = 0;
            if (i + 1 >= argc || parse_size(argv[++i], &th)) {
                usage(argv[0]);
                return 1;
            }
            opts.threads = (int)th;
        } else if (!strcmp(argv[i], "--slope")) {
            if (i + 1 >= argc || parse_double(argv[++i], &opts.slope_per_ms)) {
                usage(argv[0]);
                return 1;
            }
        } else if (!strcmp(argv[i], "--no-prefault")) {
            opts.prefault = 0;
        } else if (!strcmp(argv[i], "--read-only")) {
            opts.write_mode = 0;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (opts.threads <= 0 || opts.stride == 0 || opts.bytes < opts.stride || opts.slope_per_ms <= 0.0) {
        fprintf(stderr, "Invalid parameters: threads=%d bytes=%zu stride=%zu slope=%.2f\n",
                opts.threads, opts.bytes, opts.stride, opts.slope_per_ms);
        return 1;
    }

    const size_t alignment = 4096;
    size_t alloc_len = align_up(opts.bytes, alignment);
    uint8_t *buffer = NULL;
    if (posix_memalign((void **)&buffer, alignment, alloc_len) != 0 || buffer == NULL) {
        perror("posix_memalign");
        return 1;
    }

    if (opts.prefault)
        prefault_buffer(buffer, alloc_len, opts.stride);

    volatile uint64_t sink = 0;
    volatile int start_flag = 0;

    pthread_t *threads = calloc((size_t)opts.threads, sizeof(*threads));
    struct worker_args *args = calloc((size_t)opts.threads, sizeof(*args));
    struct worker_result *results = calloc((size_t)opts.threads, sizeof(*results));

    if (!threads || !args || !results) {
        perror("calloc");
        free((void *)buffer);
        free(threads);
        free(args);
        free(results);
        return 1;
    }

    size_t offset_step = opts.bytes / (size_t)opts.threads;
    if (offset_step == 0)
        offset_step = opts.stride;

    double ratio = SLOPE_BASELINE / opts.slope_per_ms;
    size_t hits_per_stride = (size_t)(ratio + 0.999999);
    if (hits_per_stride < 1)
        hits_per_stride = 1;
    if (hits_per_stride > MAX_HITS_PER_STRIDE)
        hits_per_stride = MAX_HITS_PER_STRIDE;

    int launched = 0;
    for (int t = 0; t < opts.threads; t++) {
        size_t start_offset = ((size_t)t * offset_step) % opts.bytes;

        args[t] = (struct worker_args){
            .buffer = buffer,
            .bytes = opts.bytes,
            .stride = opts.stride,
            .slope_per_ms = opts.slope_per_ms,
            .duration_ms = opts.duration_ms,
            .write_mode = opts.write_mode,
            .start_offset = start_offset,
            .hits_per_stride = hits_per_stride,
            .result = &results[t],
            .start_flag = &start_flag,
        };

        if (pthread_create(&threads[t], NULL, run_worker, &args[t]) != 0) {
            perror("pthread_create");
            break;
        }
        launched++;
    }

    if (launched == 0) {
        fprintf(stderr, "No worker threads launched\n");
        free(results);
        free(args);
        free(threads);
        free((void *)buffer);
        return 1;
    }

    uint64_t global_start = now_ns();
    start_flag = 1;
    for (int t = 0; t < launched; t++)
        pthread_join(threads[t], NULL);
    uint64_t global_end = now_ns();

    uint64_t total_accesses = 0;
    double min_runtime_ms = DBL_MAX, max_runtime_ms = 0.0, sum_runtime_ms = 0.0;
    double min_thread_slope = DBL_MAX, max_thread_slope = 0.0, sum_thread_slope = 0.0;
    double min_thread_gibps = DBL_MAX, max_thread_gibps = 0.0, sum_thread_gibps = 0.0;
    double hits_per_stride_d = (double)hits_per_stride;

    for (int t = 0; t < launched; t++) {
        total_accesses += results[t].accesses;

        double thread_runtime_ms = (double)results[t].runtime_ns / 1.0e6;
        double thread_stride_slope = thread_runtime_ms > 0.0 ? (((double)results[t].accesses / hits_per_stride_d) / thread_runtime_ms) : 0.0;
        double thread_gibps = thread_runtime_ms > 0.0 ? (((double)results[t].accesses * (double)opts.stride) / thread_runtime_ms) * 1000.0 / (1024.0 * 1024.0 * 1024.0) : 0.0;

        sum_runtime_ms += thread_runtime_ms;
        sum_thread_slope += thread_stride_slope;
        sum_thread_gibps += thread_gibps;

        if (thread_runtime_ms < min_runtime_ms)
            min_runtime_ms = thread_runtime_ms;
        if (thread_runtime_ms > max_runtime_ms)
            max_runtime_ms = thread_runtime_ms;

        if (thread_stride_slope < min_thread_slope)
            min_thread_slope = thread_stride_slope;
        if (thread_stride_slope > max_thread_slope)
            max_thread_slope = thread_stride_slope;

        if (thread_gibps < min_thread_gibps)
            min_thread_gibps = thread_gibps;
        if (thread_gibps > max_thread_gibps)
            max_thread_gibps = thread_gibps;

        sink += results[t].sink;
    }

    double avg_runtime_ms = sum_runtime_ms / launched;
    double avg_thread_slope = sum_thread_slope / launched;
    double avg_thread_gibps = sum_thread_gibps / launched;

    double runtime_ms = max_runtime_ms > 0.0 ? max_runtime_ms : (double)(global_end - global_start) / 1.0e6;
    double achieved_slope = runtime_ms > 0.0 ? (((double)total_accesses / hits_per_stride_d) / runtime_ms) : 0.0;
    double bytes_touched = (double)total_accesses * (double)opts.stride;
    double gib_per_s = runtime_ms > 0.0 ? (bytes_touched / runtime_ms) * 1000.0 / (1024.0 * 1024.0 * 1024.0) : 0.0;

        printf("seq_slope_bench: threads=%d bytes=%zu stride=%zu duration_ms=%" PRIu64 " target_stride_slope=%.2f strides/ms hits_per_stride=%zu achieved_stride_slope=%.2f strides/ms touched_bytes=%.0f throughput_GiB_per_s=%.3f mode=%s\n",
            launched,
            opts.bytes,
            opts.stride,
            opts.duration_ms,
            opts.slope_per_ms,
            hits_per_stride,
            achieved_slope,
            bytes_touched,
            gib_per_s,
            opts.write_mode ? "write" : "read");

    printf(" per-thread: runtime_ms min/avg/max=%.2f/%.2f/%.2f slope strides/ms min/avg/max=%.2f/%.2f/%.2f throughput_GiB_per_s min/avg/max=%.3f/%.3f/%.3f\n",
           min_runtime_ms, avg_runtime_ms, max_runtime_ms,
           min_thread_slope, avg_thread_slope, max_thread_slope,
           min_thread_gibps, avg_thread_gibps, max_thread_gibps);

    free(results);
    free(args);
    free(threads);
    sink += buffer[0];
    free((void *)buffer);
    return (sink == 0xdeadbeefULL) ? 0 : 0;
}
