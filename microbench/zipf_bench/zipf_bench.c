/*
 * zipf_bench: page-granular Zipfian memory access microbenchmark.
 *
 * A buffer of --bytes is split into pages of --page-size. Each access picks a
 * page rank k in [1, N] with P(k) ~ 1/k^s (Zipf exponent s), maps the rank to
 * a page (randomly permuted by default, so hot pages are scattered across the
 * address space), and touches one random cache line in that page.
 *
 * The skew can be given directly (--theta s) or as a hot-set rule
 * (--hot-frac F --hot-access A: fraction A of accesses go to the hottest
 * fraction F of pages), in which case s is solved for numerically.
 *
 * Sampling uses rejection-inversion (Hormann & Derflinger 1996), which is
 * exact for any s >= 0 and needs no per-rank table.
 *
 * Perf (--perf-out PREFIX): every worker is pinned to its own physical core
 * and opens a PEBS L3-miss load event (MEM_LOAD_RETIRED.L3_MISS) in period
 * mode on that core. The "unaccounted" fraction (counter value vs samples x
 * period) is reported so silent PEBS record loss is visible. A monitor thread on a separate core drains the rings and writes
 *   PREFIX_samples.bin  fixed 24-byte records (see struct sample_rec)
 *   PREFIX_lost.csv     PERF_RECORD_LOST / LOST_SAMPLES / (UN)THROTTLE
 *   PREFIX_meta.json    buffer range, events, run window, totals
 *   PREFIX_perm.bin     u32 rank-1 -> page map (only with shuffled layout)
 * Sample times are in perf clock ns; the run window in the meta file is on
 * the same clock. use_clockid is deliberately not used: it disables large
 * (multi-record) PEBS, which is what keeps period-1007 sampling cheap.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <linux/bpf.h>
#include <linux/perf_event.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <x86intrin.h>
#endif

#define CACHE_LINE 64
#define CHECK_INTERVAL 1024 /* accesses between clock checks */
#define NEVENTS 1

enum { EV_L3_MISS = 0 };
static const char *const ev_names[NEVENTS] = {"l3_miss"};

struct options {
    size_t bytes;
    size_t page_size;
    double duration_s;
    double hot_frac;
    double hot_access;
    double theta; /* < 0: derive from hot_frac/hot_access */
    int threads;
    int prefault;
    int write_mode;
    int shuffle;
    int thp; /* madvise(MADV_HUGEPAGE) on the buffer */
    int pin;
    const char *cpu_list;
    uint64_t seed;
    /* perf */
    const char *perf_out; /* NULL: perf disabled */
    uint64_t perf_period;
    size_t perf_ring_pages;
    uint64_t ev_config[NEVENTS];
    uint64_t ev_period[NEVENTS];
    int nev;
    int perf_keep_all; /* also log samples outside the buffer */
    int perf_drop_all; /* attach a BPF filter that drops every sample in-kernel */
    int bpf_prog_fd;
};

/* ---------------------------------------------------------------- RNG */

struct rng {
    uint64_t s[4];
};

static uint64_t splitmix64(uint64_t *x)
{
    uint64_t z = (*x += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

static void rng_seed(struct rng *r, uint64_t seed)
{
    for (int i = 0; i < 4; i++)
        r->s[i] = splitmix64(&seed);
}

static inline uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

static inline uint64_t rng_next(struct rng *r) /* xoshiro256** */
{
    uint64_t *s = r->s;
    uint64_t result = rotl(s[1] * 5, 7) * 9;
    uint64_t t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 45);
    return result;
}

static inline double rng_double(struct rng *r) /* [0, 1) */
{
    return (double)(rng_next(r) >> 11) * 0x1.0p-53;
}

/* ------------------------------------------------- Zipf sampler (exact) */

struct zipf {
    double s;
    double n;
    double h_int_x1;
    double h_int_n;
    double sv;
};

static inline double helper1(double x) /* log1p(x)/x */
{
    return fabs(x) > 1e-8 ? log1p(x) / x : 1.0 - x * (0.5 - x * (1.0 / 3.0 - 0.25 * x));
}

static inline double helper2(double x) /* expm1(x)/x */
{
    return fabs(x) > 1e-8 ? expm1(x) / x : 1.0 + x * 0.5 * (1.0 + x * (1.0 / 3.0) * (1.0 + 0.25 * x));
}

static inline double zh(const struct zipf *z, double x) { return exp(-z->s * log(x)); }

static inline double zh_int(const struct zipf *z, double x)
{
    double lx = log(x);
    return helper2((1.0 - z->s) * lx) * lx;
}

static inline double zh_int_inv(const struct zipf *z, double x)
{
    double t = x * (1.0 - z->s);
    if (t < -1.0)
        t = -1.0;
    return exp(helper1(t) * x);
}

static void zipf_init(struct zipf *z, uint64_t n, double s)
{
    z->s = s;
    z->n = (double)n;
    z->h_int_x1 = zh_int(z, 1.5) - 1.0;
    z->h_int_n = zh_int(z, z->n + 0.5);
    z->sv = 2.0 - zh_int_inv(z, zh_int(z, 2.5) - zh(z, 2.0));
}

static inline uint64_t zipf_sample(const struct zipf *z, struct rng *r) /* rank in [1, n] */
{
    for (;;) {
        double u = z->h_int_n + rng_double(r) * (z->h_int_x1 - z->h_int_n);
        double x = zh_int_inv(z, u);
        double k = floor(x + 0.5);
        if (k < 1.0)
            k = 1.0;
        else if (k > z->n)
            k = z->n;
        if (k - x <= z->sv || u >= zh_int(z, k + 0.5) - zh(z, k))
            return (uint64_t)k;
    }
}

/* --------------------------------------- generalized harmonic H(n, s) */

/* Exact sum for the first terms, Euler-Maclaurin for the tail. */
static double harmonic(uint64_t n, double s)
{
    const uint64_t m = n < 10000 ? n : 10000;
    double sum = 0.0;
    for (uint64_t k = 1; k <= m; k++)
        sum += pow((double)k, -s);
    if (n == m)
        return sum;
    double a = (double)m, b = (double)n;
    double integral = fabs(1.0 - s) < 1e-12 ? log(b / a)
                                            : (pow(b, 1.0 - s) - pow(a, 1.0 - s)) / (1.0 - s);
    double fa = pow(a, -s), fb = pow(b, -s);
    double dfa = -s * pow(a, -s - 1.0), dfb = -s * pow(b, -s - 1.0);
    /* sum_{k=m+1}^{n} f(k) = integral + (f(b) - f(a))/2 + (f'(b) - f'(a))/12 */
    return sum + integral + 0.5 * (fb - fa) + (dfb - dfa) / 12.0;
}

static double hot_share(uint64_t n, uint64_t hot_n, double s)
{
    return harmonic(hot_n, s) / harmonic(n, s);
}

static double solve_theta(uint64_t n, uint64_t hot_n, double target)
{
    double lo = 0.0, hi = 1.0;
    while (hot_share(n, hot_n, hi) < target && hi < 64.0)
        hi *= 2.0;
    for (int i = 0; i < 60; i++) {
        double mid = 0.5 * (lo + hi);
        if (hot_share(n, hot_n, mid) < target)
            lo = mid;
        else
            hi = mid;
    }
    return 0.5 * (lo + hi);
}

/* ---------------------------------------------------------- CPU choice */

static int read_sysfs_int(int cpu, const char *leaf)
{
    char path[128];
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/topology/%s", cpu, leaf);
    FILE *f = fopen(path, "r");
    int v = -1;
    if (f) {
        if (fscanf(f, "%d", &v) != 1)
            v = -1;
        fclose(f);
    }
    return v;
}

/* Parse "0-3,8,10-11" into out[]; returns count or -1. */
static int parse_cpu_list(const char *s, int *out, int max)
{
    int n = 0;
    while (*s) {
        char *end;
        long a = strtol(s, &end, 10), b;
        if (end == s)
            return -1;
        b = a;
        if (*end == '-') {
            s = end + 1;
            b = strtol(s, &end, 10);
            if (end == s || b < a)
                return -1;
        }
        for (long c = a; c <= b; c++) {
            if (n >= max)
                return -1;
            out[n++] = (int)c;
        }
        s = end;
        if (*s == ',')
            s++;
        else if (*s)
            return -1;
    }
    return n;
}

/*
 * Pick ncpu CPUs from the process affinity mask (so numactl --cpunodebind is
 * respected), one per physical core first, then hyperthread siblings.
 * Returns the number of distinct CPUs available in order[] (may be < ncpu).
 */
static int order_cpus(int *order, int max)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set))
        return 0;
    int allowed[CPU_SETSIZE], na = 0;
    for (int c = 0; c < CPU_SETSIZE; c++)
        if (CPU_ISSET(c, &set))
            allowed[na++] = c;

    long *keys = calloc((size_t)na, sizeof(*keys));
    char *used = calloc((size_t)na, 1);
    int n = 0;
    for (int i = 0; i < na; i++) /* first pass: one CPU per physical core */
    {
        long key = ((long)read_sysfs_int(allowed[i], "physical_package_id") << 20) |
                   (read_sysfs_int(allowed[i], "core_id") & 0xfffff);
        int dup = 0;
        for (int j = 0; j < n; j++)
            dup |= keys[j] == key;
        if (!dup && n < max) {
            keys[n] = key;
            order[n++] = allowed[i];
            used[i] = 1;
        }
    }
    for (int i = 0; i < na && n < max; i++) /* second pass: siblings */
        if (!used[i])
            order[n++] = allowed[i];
    free(keys);
    free(used);
    return n;
}

static int pin_self(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

/* ---------------------------------------------------------------- perf */

struct sample_rec { /* on-disk, 24 bytes, little-endian */
    uint64_t time_ns; /* perf clock */
    uint64_t addr;    /* data virtual address */
    uint16_t thread;  /* worker index (cpu in meta) */
    uint8_t event;    /* EV_L3_MISS */
    uint8_t pad[5];
};
_Static_assert(sizeof(struct sample_rec) == 24, "sample_rec layout");

struct ring {
    int nev;
    int fd[NEVENTS];
    uint64_t id[NEVENTS];
    struct perf_event_mmap_page *mp;
    size_t mmap_len;
    size_t data_size;
    uint64_t samples[NEVENTS];
    uint64_t outside[NEVENTS]; /* samples outside the buffer (dropped unless keep_all) */
    uint64_t lost[NEVENTS];
    uint64_t throttles[NEVENTS];
    uint64_t count[NEVENTS]; /* exact counter value at end */
};

static long perf_event_open(struct perf_event_attr *a, pid_t pid, int cpu, int group, unsigned long fl)
{
    return syscall(__NR_perf_event_open, a, pid, cpu, group, fl);
}

/* BPF_PROG_TYPE_PERF_EVENT program "return 0": drops every sample before the
 * ring buffer. Needs root, and the pebs-bpf-filter-large-pebs patch for
 * large-PEBS records to be filtered (stock kernels only filter the last one). */
static int load_drop_all_prog(void)
{
    struct bpf_insn insns[] = {
        {.code = BPF_ALU64 | BPF_MOV | BPF_K, .dst_reg = 0, .imm = 0},
        {.code = BPF_JMP | BPF_EXIT},
    };
    union bpf_attr a;
    memset(&a, 0, sizeof(a));
    a.prog_type = BPF_PROG_TYPE_PERF_EVENT;
    a.insns = (uint64_t)(uintptr_t)insns;
    a.insn_cnt = 2;
    a.license = (uint64_t)(uintptr_t)"GPL";
    return (int)syscall(__NR_bpf, BPF_PROG_LOAD, &a, sizeof(a));
}

/* Open both events for the calling thread on `cpu`, sharing one ring. */
static int perf_open_ring(struct ring *r, int cpu, const struct options *o)
{
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    r->nev = o->nev;
    for (int e = 0; e < o->nev; e++) {
        struct perf_event_attr a;
        memset(&a, 0, sizeof(a));
        a.size = sizeof(a);
        a.type = PERF_TYPE_RAW;
        a.config = o->ev_config[e];
        a.sample_period = o->ev_period[e]; /* period mode (freq = 0) */
        a.sample_type = PERF_SAMPLE_IDENTIFIER | PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_ADDR;
        a.precise_ip = 2;
        a.disabled = 1;
        a.exclude_kernel = 1;
        a.exclude_hv = 1;
        a.sample_id_all = 1;
        a.watermark = 1;
        a.wakeup_watermark = (uint32_t)(o->perf_ring_pages * pg / 4);
        r->fd[e] = (int)perf_event_open(&a, 0, cpu, -1, PERF_FLAG_FD_CLOEXEC);
        if (r->fd[e] < 0) {
            fprintf(stderr, "perf_event_open(%s config=0x%" PRIx64 " cpu=%d): %s\n", ev_names[e],
                    o->ev_config[e], cpu, strerror(errno));
            return -1;
        }
        if (ioctl(r->fd[e], PERF_EVENT_IOC_ID, &r->id[e])) {
            perror("PERF_EVENT_IOC_ID");
            return -1;
        }
    }
    r->data_size = o->perf_ring_pages * pg;
    r->mmap_len = r->data_size + pg;
    void *m = mmap(NULL, r->mmap_len, PROT_READ | PROT_WRITE, MAP_SHARED, r->fd[0], 0);
    if (m == MAP_FAILED) {
        fprintf(stderr, "perf mmap (%zu pages) cpu=%d: %s\n", o->perf_ring_pages, cpu, strerror(errno));
        return -1;
    }
    r->mp = m;
    return 0;
}

static void perf_ctl(struct ring *r, unsigned long req)
{
    for (int e = 0; e < r->nev; e++)
        ioctl(r->fd[e], req, 0);
}

/* Current time on the perf sample clock, via the mmap page's TSC params. */
static uint64_t perf_clock_now(const struct perf_event_mmap_page *mp)
{
#if defined(__x86_64__)
    if (mp && mp->cap_user_time_zero) {
        uint64_t cyc = __rdtsc();
        uint64_t quot = cyc >> mp->time_shift;
        uint64_t rem = cyc & (((uint64_t)1 << mp->time_shift) - 1);
        return mp->time_zero + quot * mp->time_mult + ((rem * mp->time_mult) >> mp->time_shift);
    }
#endif
    (void)mp;
    return 0;
}

struct monitor {
    pthread_t tid;
    struct ring *rings;
    int nrings;
    const int *cpus;
    FILE *samples;
    FILE *lost;
    uint64_t lo, hi; /* buffer VA range */
    int keep_all;
    volatile int stop;
};

static int ev_index(const struct ring *r, uint64_t id)
{
    for (int e = 0; e < r->nev; e++)
        if (r->id[e] == id)
            return e;
    return -1;
}

static void handle_record(struct monitor *m, int t, const struct perf_event_header *h)
{
    struct ring *r = &m->rings[t];
    const uint64_t *p = (const uint64_t *)(h + 1);
    switch (h->type) {
    case PERF_RECORD_SAMPLE: { /* identifier, pid|tid, time, addr */
        int e = ev_index(r, p[0]);
        if (e < 0)
            return;
        if (p[3] < m->lo || p[3] >= m->hi) {
            r->outside[e]++;
            if (!m->keep_all)
                return;
        }
        struct sample_rec rec = {.time_ns = p[2], .addr = p[3], .thread = (uint16_t)t, .event = (uint8_t)e};
        fwrite(&rec, sizeof(rec), 1, m->samples);
        r->samples[e]++;
        break;
    }
    case PERF_RECORD_LOST: { /* id, lost, sample_id{pid|tid, time, identifier} */
        int e = ev_index(r, p[0]);
        if (e >= 0)
            r->lost[e] += p[1];
        fprintf(m->lost, "%" PRIu64 ",%d,%d,lost,%s,%" PRIu64 "\n", p[3], t, m->cpus[t],
                e >= 0 ? ev_names[e] : "?", p[1]);
        break;
    }
    case PERF_RECORD_LOST_SAMPLES: { /* lost, sample_id{pid|tid, time, identifier} */
        int e = ev_index(r, p[3]);
        if (e >= 0)
            r->lost[e] += p[0];
        fprintf(m->lost, "%" PRIu64 ",%d,%d,lost_samples,%s,%" PRIu64 "\n", p[2], t, m->cpus[t],
                e >= 0 ? ev_names[e] : "?", p[0]);
        break;
    }
    case PERF_RECORD_THROTTLE:
    case PERF_RECORD_UNTHROTTLE: { /* time, id, stream_id, sample_id */
        int e = ev_index(r, p[1]);
        if (e >= 0 && h->type == PERF_RECORD_THROTTLE)
            r->throttles[e]++;
        fprintf(m->lost, "%" PRIu64 ",%d,%d,%s,%s,1\n", p[0], t, m->cpus[t],
                h->type == PERF_RECORD_THROTTLE ? "throttle" : "unthrottle", e >= 0 ? ev_names[e] : "?");
        break;
    }
    default:
        break;
    }
}

static int drain_ring(struct monitor *m, int t)
{
    struct ring *r = &m->rings[t];
    uint8_t *data = (uint8_t *)r->mp + r->mp->data_offset;
    uint64_t size = r->mp->data_size;
    uint64_t head = __atomic_load_n(&r->mp->data_head, __ATOMIC_ACQUIRE);
    uint64_t tail = r->mp->data_tail;
    uint64_t start = tail;
    uint8_t tmp[256];

    while (tail < head) {
        uint64_t off = tail & (size - 1);
        struct perf_event_header *h = (struct perf_event_header *)(data + off);
        if (h->size == 0)
            break;
        if (off + h->size > size) { /* record wraps: linearize */
            size_t first = size - off;
            if (h->size <= sizeof(tmp)) {
                memcpy(tmp, data + off, first);
                memcpy(tmp + first, data, h->size - first);
                handle_record(m, t, (struct perf_event_header *)tmp);
            }
        } else {
            handle_record(m, t, h);
        }
        tail += h->size;
    }
    __atomic_store_n(&r->mp->data_tail, tail, __ATOMIC_RELEASE);
    return tail != start;
}

static void *run_monitor(void *arg)
{
    struct monitor *m = arg;
    struct pollfd *pfd = calloc((size_t)m->nrings, sizeof(*pfd));
    for (int t = 0; t < m->nrings; t++)
        pfd[t] = (struct pollfd){.fd = m->rings[t].fd[0], .events = POLLIN};
    while (!m->stop) {
        poll(pfd, (nfds_t)m->nrings, 10);
        for (int t = 0; t < m->nrings; t++)
            drain_ring(m, t);
    }
    for (int t = 0; t < m->nrings; t++) /* final drain after workers disabled */
        while (drain_ring(m, t))
            ;
    free(pfd);
    return NULL;
}

/* ------------------------------------------------------------ workers */

struct shared {
    uint8_t *buf;
    const uint32_t *perm; /* rank-1 -> page; NULL = identity */
    uint64_t pages;
    uint64_t hot_n;
    size_t page_size;
    size_t lines_per_page;
    uint64_t duration_ns;
    int write_mode;
    struct zipf zipf;
    const struct options *opts;
    int ready;  /* atomic: workers that finished setup */
    int failed; /* atomic: workers whose setup failed */
    volatile int start;
    volatile int abort;
};

struct worker {
    pthread_t tid;
    struct shared *sh;
    int cpu; /* -1: unpinned */
    struct ring *ring; /* NULL: no perf */
    uint64_t seed;
    uint64_t accesses;
    uint64_t hot_accesses;
    uint64_t runtime_ns;
    uint64_t sink;
    pid_t ktid;
};

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Per-thread CPU of this process's non-worker threads: a preloaded tiering
 * runtime (ARMS names its threads arms-*) plus our own main/monitor. */
#define MAX_TASKS 256
struct tstat {
    pid_t tid;
    char comm[16];
    double ticks;
};

static int task_snapshot(const struct worker *w, int n, struct tstat *out)
{
    DIR *d = opendir("/proc/self/task");
    if (!d)
        return 0;
    int k = 0;
    struct dirent *e;
    while (k < MAX_TASKS && (e = readdir(d))) {
        pid_t tid = (pid_t)atoi(e->d_name);
        if (tid <= 0)
            continue;
        int worker = 0;
        for (int i = 0; i < n; i++)
            worker |= w[i].ktid == tid;
        if (worker)
            continue;
        char path[64], line[1024];
        snprintf(path, sizeof(path), "/proc/self/task/%d/stat", tid);
        FILE *f = fopen(path, "r");
        if (!f)
            continue;
        char *l = fgets(line, sizeof(line), f), *open = l ? strchr(line, '(') : NULL,
             *close = l ? strrchr(line, ')') : NULL;
        fclose(f);
        unsigned long ut, st;
        /* after "pid (comm)": state is field 3, utime/stime are 14/15 */
        if (!open || !close || close < open ||
            sscanf(close + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu", &ut, &st) != 2)
            continue;
        size_t len = (size_t)(close - open - 1);
        if (len > 15)
            len = 15;
        memcpy(out[k].comm, open + 1, len);
        out[k].comm[len] = 0;
        out[k].tid = tid;
        out[k].ticks = (double)(ut + st);
        k++;
    }
    closedir(d);
    return k;
}

/* CPU seconds per thread name between two snapshots; threads that exited
 * before `b` are not counted. Returns the number of names in `by`. */
static int aux_by_name(const struct tstat *a, int na, const struct tstat *b, int nb, struct tstat *by,
                       double *total)
{
    int nby = 0;
    *total = 0;
    double hz = (double)sysconf(_SC_CLK_TCK);
    for (int i = 0; i < nb; i++) {
        double t0 = 0;
        for (int j = 0; j < na; j++)
            if (a[j].tid == b[i].tid)
                t0 = a[j].ticks;
        double sec = (b[i].ticks - t0) / hz;
        *total += sec;
        int j = 0;
        while (j < nby && strcmp(by[j].comm, b[i].comm))
            j++;
        if (j == nby) {
            by[nby] = b[i];
            by[nby++].ticks = 0;
        }
        by[j].ticks += sec;
    }
    return nby;
}

static void *run_worker(void *arg)
{
    struct worker *w = arg;
    w->ktid = (pid_t)syscall(SYS_gettid);
    struct shared *sh = w->sh;
    struct rng r;
    rng_seed(&r, w->seed);

    int ok = 1;
    if (w->cpu >= 0 && pin_self(w->cpu)) {
        fprintf(stderr, "failed to pin worker to cpu %d\n", w->cpu);
        ok = 0;
    }
    if (ok && w->ring && perf_open_ring(w->ring, w->cpu, sh->opts))
        ok = 0;
    if (ok && w->ring && sh->opts->perf_drop_all &&
        ioctl(w->ring->fd[0], PERF_EVENT_IOC_SET_BPF, sh->opts->bpf_prog_fd)) {
        perror("PERF_EVENT_IOC_SET_BPF");
        ok = 0;
    }
    __atomic_add_fetch(ok ? &sh->ready : &sh->failed, 1, __ATOMIC_RELEASE);

    while (!sh->start)
        __asm__ __volatile__("" ::: "memory");
    if (!ok || sh->abort)
        return NULL;

    uint64_t accesses = 0, hot = 0, sink = 0;
    if (w->ring)
        perf_ctl(w->ring, PERF_EVENT_IOC_ENABLE);
    const uint64_t start = now_ns();
    uint64_t now = start;
    do {
        for (int i = 0; i < CHECK_INTERVAL; i++) {
            uint64_t rank = zipf_sample(&sh->zipf, &r);
            hot += rank <= sh->hot_n;
            uint64_t page = sh->perm ? sh->perm[rank - 1] : rank - 1;
            size_t line = (size_t)(rng_next(&r) % sh->lines_per_page);
            volatile uint8_t *p = sh->buf + page * sh->page_size + line * CACHE_LINE;
            if (sh->write_mode)
                *p += 1;
            else
                sink += *p;
        }
        accesses += CHECK_INTERVAL;
        now = now_ns();
    } while (now - start < sh->duration_ns);
    if (w->ring) {
        perf_ctl(w->ring, PERF_EVENT_IOC_DISABLE);
        for (int e = 0; e < w->ring->nev; e++)
            if (read(w->ring->fd[e], &w->ring->count[e], sizeof(uint64_t)) != sizeof(uint64_t))
                w->ring->count[e] = 0;
    }

    w->accesses = accesses;
    w->hot_accesses = hot;
    w->runtime_ns = now - start;
    w->sink = sink;
    return NULL;
}

struct prefault_arg {
    pthread_t tid;
    uint8_t *buf;
    size_t len;
};

static void *prefault_worker(void *arg)
{
    struct prefault_arg *a = arg;
    for (size_t i = 0; i < a->len; i += 4096)
        a->buf[i] = 1;
    return NULL;
}

static void prefault(uint8_t *buf, size_t len, int threads)
{
    struct prefault_arg *a = calloc((size_t)threads, sizeof(*a));
    size_t chunk = (len / (size_t)threads + 4095) & ~(size_t)4095;
    int launched = 0;
    for (int t = 0; t < threads; t++) {
        size_t off = (size_t)t * chunk;
        if (off >= len)
            break;
        a[t].buf = buf + off;
        a[t].len = off + chunk > len ? len - off : chunk;
        pthread_create(&a[t].tid, NULL, prefault_worker, &a[t]);
        launched++;
    }
    for (int t = 0; t < launched; t++)
        pthread_join(a[t].tid, NULL);
    free(a);
}

/* AnonHugePages (kB) of the VMA containing addr, from /proc/self/smaps. */
static long anon_huge_kb(const void *addr)
{
    FILE *f = fopen("/proc/self/smaps", "r");
    if (!f)
        return -1;
    char line[512];
    int in = 0;
    long kb = -1;
    uintptr_t a = (uintptr_t)addr;
    while (fgets(line, sizeof(line), f)) {
        unsigned long lo, hi;
        if (sscanf(line, "%lx-%lx ", &lo, &hi) == 2 && strchr(line, '-') < strchr(line, ' ')) {
            in = a >= lo && a < hi;
        } else if (in && sscanf(line, "AnonHugePages: %ld kB", &kb) == 1) {
            break;
        }
    }
    fclose(f);
    return kb;
}

static long g_anon_huge_kb = -1;
static uint64_t g_accesses;
static double g_runtime_s;
static double g_aux_cpu_s;
static struct tstat g_aux_by[MAX_TASKS];
static int g_naux;

/* --------------------------------------------------------------- main */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  --bytes N            Buffer size in bytes (default: 32 GiB)\n"
            "  --size-gb G          Buffer size in GiB (alternative to --bytes)\n"
            "  --page-size N        Access granularity in bytes, multiple of 64 (default: 4096)\n"
            "  --duration-s S       Run time in seconds (default: 60)\n"
            "  --hot-frac F         Hottest fraction of pages ... (default: 0.2)\n"
            "  --hot-access A       ... that receives this fraction of accesses (default: 0.8)\n"
            "  --theta S            Zipf exponent; overrides --hot-frac/--hot-access\n"
            "  --threads N          Worker threads (default: 1)\n"
            "  --seed N             RNG seed (default: 1)\n"
            "  --no-shuffle         Hot pages contiguous at the buffer start (default: scattered)\n"
            "  --thp                Back the buffer with 2 MiB transparent huge pages (madvise)\n"
            "  --no-prefault        Skip touching the buffer before the timed run\n"
            "  --read-only          Issue loads instead of read-modify-write increments\n"
            "  --no-pin             Do not pin workers (default: one physical core each)\n"
            "  --cpus LIST          Explicit worker CPUs, e.g. 0-7 (monitor takes the next allowed CPU)\n"
            "Perf (enabled by --perf-out):\n"
            "  --perf-out PREFIX    Write PREFIX_{samples.bin,lost.csv,meta.json,perm.bin}\n"
            "  --perf-period N      PEBS sample period for the L3-miss event (default: 1007)\n"
            "  --perf-ring-pages N  Ring buffer data pages per core, power of 2 (default: 512)\n"
            "  --perf-miss-event X  Raw config for L3-miss loads (default: 0x20d1 MEM_LOAD_RETIRED.L3_MISS)\n"

            "  --perf-keep-all      Also log samples outside the buffer (default: count, then drop)\n"
            "  --perf-drop-all      Attach a BPF filter that drops every sample in-kernel (root;\n"
            "                       measures cost of ring-buffer copy and onwards)\n",
            prog);
}

static int parse_u64(const char *s, uint64_t *out)
{
    char *end;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || end == s || *end)
        return -1;
    *out = v;
    return 0;
}

static int parse_dbl(const char *s, double *out)
{
    char *end;
    errno = 0;
    double v = strtod(s, &end);
    if (errno || end == s || *end)
        return -1;
    *out = v;
    return 0;
}

static void write_meta(const char *path, const struct options *o, const struct shared *sh, size_t len,
                       double theta, double expected_hot, const struct worker *w, int nthreads,
                       int monitor_cpu, uint64_t t_start, uint64_t t_end, const struct ring *rings)
{
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        return;
    }
    fprintf(f, "{\n  \"buf_base\": %" PRIu64 ",\n  \"buf_len\": %zu,\n  \"page_size\": %zu,\n",
            (uint64_t)(uintptr_t)sh->buf, len, o->page_size);
    fprintf(f, "  \"pages\": %" PRIu64 ",\n  \"hot_pages\": %" PRIu64 ",\n  \"theta\": %.9f,\n", sh->pages,
            sh->hot_n, theta);
    fprintf(f, "  \"expected_hot_access\": %.6f,\n  \"hot_frac\": %g,\n  \"hot_access\": %g,\n", expected_hot,
            o->hot_frac, o->hot_access);
    fprintf(f, "  \"thp\": %s,\n  \"anon_huge_bytes\": %ld,\n", o->thp ? "true" : "false",
            g_anon_huge_kb < 0 ? -1L : g_anon_huge_kb * 1024L);
    fprintf(f, "  \"layout\": \"%s\",\n  \"mode\": \"%s\",\n  \"threads\": %d,\n",
            o->shuffle ? "scattered" : "contiguous", o->write_mode ? "write" : "read", nthreads);
    fprintf(f, "  \"cpus\": [");
    for (int t = 0; t < nthreads; t++)
        fprintf(f, "%s%d", t ? ", " : "", w[t].cpu);
    fprintf(f, "],\n  \"monitor_cpu\": %d,\n", monitor_cpu);
    fprintf(f, "  \"accesses\": %" PRIu64 ",\n  \"runtime_s\": %.6f,\n  \"maccesses_per_s\": %.4f,\n",
            g_accesses, g_runtime_s, g_runtime_s > 0 ? (double)g_accesses / g_runtime_s / 1e6 : 0.0);
    fprintf(f, "  \"aux_cpu_s\": %.3f,\n", g_aux_cpu_s);
    fprintf(f, "  \"aux_cpu_by_thread\": {");
    for (int i = 0; i < g_naux; i++)
        fprintf(f, "%s\"%s\": %.3f", i ? ", " : "", g_aux_by[i].comm, g_aux_by[i].ticks);
    fprintf(f, "},\n");
    fprintf(f, "  \"perf_period\": %" PRIu64 ",\n  \"perf_ring_pages\": %zu,\n", o->ev_period[0],
            o->perf_ring_pages);
    fprintf(f, "  \"t_start_ns\": %" PRIu64 ",\n  \"t_end_ns\": %" PRIu64 ",\n", t_start, t_end);
    fprintf(f, "  \"record\": {\"size\": 24, \"fields\": [[\"time_ns\", \"<u8\"], [\"addr\", \"<u8\"], "
               "[\"thread\", \"<u2\"], [\"event\", \"u1\"], [\"pad\", \"V5\"]]},\n");
    fprintf(f, "  \"perm_file\": %s,\n  \"keep_all\": %s,\n  \"drop_all\": %s,\n",
            o->shuffle ? "true" : "false", o->perf_keep_all ? "true" : "false",
            o->perf_drop_all ? "true" : "false");
    fprintf(f, "  \"events\": [\n");
    for (int e = 0; e < o->nev; e++) {
        uint64_t s = 0, l = 0, th = 0, c = 0, out = 0;
        for (int t = 0; t < nthreads; t++) {
            out += rings[t].outside[e];
            s += rings[t].samples[e];
            l += rings[t].lost[e];
            th += rings[t].throttles[e];
            c += rings[t].count[e];
        }
        fprintf(f,
                "    {\"index\": %d, \"name\": \"%s\", \"config\": \"0x%" PRIx64 "\", \"period\": %" PRIu64 ", \"samples\": %" PRIu64
                ", \"samples_outside_buf\": %" PRIu64 ", \"lost\": %" PRIu64 ", \"throttles\": %" PRIu64 ", \"count\": %" PRIu64 ", \"unaccounted_frac\": %.4f}%s\n",
                e, ev_names[e], o->ev_config[e], o->ev_period[e], s, out, l, th, c,
                c ? 1.0 - (double)(o->perf_keep_all ? s : s + out) * (double)o->ev_period[e] / (double)c : 0.0,
                e + 1 < o->nev ? "," : "");
    }
    fprintf(f, "  ]\n}\n");
    fclose(f);
}

int main(int argc, char **argv)
{
    struct options o = {
        .bytes = 32ull << 30,
        .page_size = 4096,
        .duration_s = 60.0,
        .hot_frac = 0.2,
        .hot_access = 0.8,
        .theta = -1.0,
        .threads = 1,
        .prefault = 1,
        .write_mode = 1,
        .shuffle = 1,
        .thp = 0,
        .pin = 1,
        .seed = 1,
        .perf_period = 1007,
        .perf_ring_pages = 512,
        .ev_config = {0x20d1},
    };

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        uint64_t u = 0;
        int bad = 0;
        if (!strcmp(a, "--bytes")) {
            bad = !v || parse_u64(v, &u);
            o.bytes = u, i++;
        } else if (!strcmp(a, "--size-gb")) {
            double g = 0;
            bad = !v || parse_dbl(v, &g);
            o.bytes = (size_t)(g * (double)(1ull << 30)), i++;
        } else if (!strcmp(a, "--page-size")) {
            bad = !v || parse_u64(v, &u);
            o.page_size = u, i++;
        } else if (!strcmp(a, "--duration-s")) {
            bad = !v || parse_dbl(v, &o.duration_s), i++;
        } else if (!strcmp(a, "--hot-frac")) {
            bad = !v || parse_dbl(v, &o.hot_frac), i++;
        } else if (!strcmp(a, "--hot-access")) {
            bad = !v || parse_dbl(v, &o.hot_access), i++;
        } else if (!strcmp(a, "--theta")) {
            bad = !v || parse_dbl(v, &o.theta), i++;
        } else if (!strcmp(a, "--threads")) {
            bad = !v || parse_u64(v, &u);
            o.threads = (int)u, i++;
        } else if (!strcmp(a, "--seed")) {
            bad = !v || parse_u64(v, &o.seed), i++;
        } else if (!strcmp(a, "--cpus")) {
            bad = !v;
            o.cpu_list = v, i++;
        } else if (!strcmp(a, "--perf-out")) {
            bad = !v;
            o.perf_out = v, i++;
        } else if (!strcmp(a, "--perf-period")) {
            bad = !v || parse_u64(v, &o.perf_period), i++;
        } else if (!strcmp(a, "--perf-ring-pages")) {
            bad = !v || parse_u64(v, &u);
            o.perf_ring_pages = u, i++;
        } else if (!strcmp(a, "--perf-miss-event")) {
            bad = !v || parse_u64(v, &o.ev_config[EV_L3_MISS]), i++;
        } else if (!strcmp(a, "--thp")) {
            o.thp = 1;
        } else if (!strcmp(a, "--no-shuffle")) {
            o.shuffle = 0;
        } else if (!strcmp(a, "--no-prefault")) {
            o.prefault = 0;
        } else if (!strcmp(a, "--read-only")) {
            o.write_mode = 0;
        } else if (!strcmp(a, "--perf-drop-all")) {
            o.perf_drop_all = 1;
        } else if (!strcmp(a, "--perf-keep-all")) {
            o.perf_keep_all = 1;
        } else if (!strcmp(a, "--no-pin")) {
            o.pin = 0;
        } else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", a);
            bad = 1;
        }
        if (bad) {
            usage(argv[0]);
            return 1;
        }
    }

    if (o.page_size < CACHE_LINE || o.page_size % CACHE_LINE || o.bytes < o.page_size ||
        o.threads <= 0 || o.threads > 65535 || o.duration_s <= 0.0) {
        fprintf(stderr, "Invalid parameters: bytes=%zu page_size=%zu threads=%d duration_s=%g\n",
                o.bytes, o.page_size, o.threads, o.duration_s);
        return 1;
    }
    if (o.perf_out) {
        if (o.perf_period == 0 || o.perf_ring_pages == 0 || (o.perf_ring_pages & (o.perf_ring_pages - 1))) {
            fprintf(stderr, "--perf-period must be > 0 and --perf-ring-pages a power of 2\n");
            return 1;
        }
        o.ev_period[EV_L3_MISS] = o.perf_period;
        o.nev = NEVENTS;
        if (!o.pin) {
            fprintf(stderr, "--perf-out requires pinning (per-core events); drop --no-pin\n");
            return 1;
        }
    }

    uint64_t pages = o.bytes / o.page_size;
    if (pages > UINT32_MAX) {
        fprintf(stderr, "Too many pages (%" PRIu64 "); increase --page-size\n", pages);
        return 1;
    }
    if (!(o.hot_frac > 0.0 && o.hot_frac < 1.0)) {
        fprintf(stderr, "--hot-frac must be in (0, 1)\n");
        return 1;
    }
    uint64_t hot_n = (uint64_t)ceil(o.hot_frac * (double)pages);
    if (hot_n < 1)
        hot_n = 1;

    double theta = o.theta;
    if (theta < 0.0) {
        if (!(o.hot_access > (double)hot_n / (double)pages && o.hot_access < 1.0)) {
            fprintf(stderr, "--hot-access must be in (hot-frac, 1)\n");
            return 1;
        }
        theta = solve_theta(pages, hot_n, o.hot_access);
    }
    double expected_hot = hot_share(pages, hot_n, theta);

    /* CPU assignment: workers first, then one more for the monitor. */
    int *cpus = malloc(((size_t)o.threads + 1) * sizeof(int));
    int monitor_cpu = -1;
    if (o.pin) {
        int avail;
        if (o.cpu_list) {
            avail = parse_cpu_list(o.cpu_list, cpus, o.threads + 1);
            if (avail < o.threads) {
                fprintf(stderr, "--cpus must list at least %d CPUs\n", o.threads);
                return 1;
            }
            if (avail == o.threads) { /* monitor: first allowed CPU not in the list */
                int order[CPU_SETSIZE], n = order_cpus(order, CPU_SETSIZE);
                for (int i = 0; i < n && avail == o.threads; i++) {
                    int dup = 0;
                    for (int t = 0; t < o.threads; t++)
                        dup |= cpus[t] == order[i];
                    if (!dup)
                        cpus[avail++] = order[i];
                }
            }
        } else {
            avail = order_cpus(cpus, o.threads + 1);
        }
        if (avail < o.threads) {
            fprintf(stderr, "Only %d CPUs available for %d threads (use --no-pin)\n", avail, o.threads);
            return 1;
        }
        if (avail > o.threads)
            monitor_cpu = cpus[o.threads];
    } else {
        for (int t = 0; t < o.threads; t++)
            cpus[t] = -1;
    }

    /* Over-allocate so the buffer starts on a 2 MiB boundary (needed for THP). */
    const size_t huge = 2u << 20;
    size_t len = pages * o.page_size;
    size_t map_len = len + huge;
    uint8_t *raw = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    uint8_t *buf = (uint8_t *)(((uintptr_t)raw + huge - 1) & ~(uintptr_t)(huge - 1));
    if (o.thp && madvise(buf, len, MADV_HUGEPAGE)) {
        perror("madvise(MADV_HUGEPAGE)");
        return 1;
    }

    uint32_t *perm = NULL;
    if (o.shuffle) {
        perm = malloc(pages * sizeof(*perm));
        if (!perm) {
            perror("malloc");
            return 1;
        }
        for (uint64_t i = 0; i < pages; i++)
            perm[i] = (uint32_t)i;
        struct rng r;
        rng_seed(&r, o.seed ^ 0x5eed5eedull);
        for (uint64_t i = pages - 1; i > 0; i--) {
            uint64_t j = rng_next(&r) % (i + 1);
            uint32_t t = perm[i];
            perm[i] = perm[j];
            perm[j] = t;
        }
    }

    printf("zipf_bench: bytes=%zu page_size=%zu pages=%" PRIu64 " hot_pages=%" PRIu64
           " (%.1f%%) theta=%.6f expected_hot_access=%.2f%% threads=%d duration_s=%g mode=%s layout=%s\n",
           len, o.page_size, pages, hot_n, 100.0 * (double)hot_n / (double)pages, theta,
           100.0 * expected_hot, o.threads, o.duration_s, o.write_mode ? "write" : "read",
           o.shuffle ? "scattered" : "contiguous");
    printf("thp: %s\n", o.thp ? "madvise(MADV_HUGEPAGE)" : "off (system default)");
    if (o.pin) {
        printf("pinning: workers on cpus");
        for (int t = 0; t < o.threads; t++)
            printf("%c%d", t ? ',' : ' ', cpus[t]);
        printf("; monitor on %s%d\n", monitor_cpu < 0 ? "(unpinned) " : "cpu ", monitor_cpu);
    }
    if (o.perf_out)
    {
        printf("perf: buf=[0x%" PRIxPTR ", 0x%" PRIxPTR ") ring_pages=%zu", (uintptr_t)buf,
               (uintptr_t)buf + len, o.perf_ring_pages);
        for (int e = 0; e < o.nev; e++)
            printf(" %s=0x%" PRIx64 "/period %" PRIu64, ev_names[e], o.ev_config[e], o.ev_period[e]);
        printf(" out=%s_*\n", o.perf_out);
    }
    fflush(stdout);

    if (o.prefault) {
        uint64_t t0 = now_ns();
        prefault(buf, len, o.threads);
        printf("prefault: %.2f s\n", (double)(now_ns() - t0) / 1e9);
        g_anon_huge_kb = anon_huge_kb(buf);
        printf("buffer AnonHugePages: %ld kB (%.1f%% of buffer)\n", g_anon_huge_kb,
               100.0 * (double)g_anon_huge_kb * 1024.0 / (double)len);
        fflush(stdout);
    }

    /* Output files are opened before workers start so a bad path fails fast. */
    char path[4096];
    struct monitor mon = {0};
    struct ring *rings = NULL;
    if (o.perf_out) {
        snprintf(path, sizeof(path), "%s_samples.bin", o.perf_out);
        mon.samples = fopen(path, "wb");
        snprintf(path, sizeof(path), "%s_lost.csv", o.perf_out);
        mon.lost = fopen(path, "w");
        if (!mon.samples || !mon.lost) {
            fprintf(stderr, "cannot open perf output %s_*: %s\n", o.perf_out, strerror(errno));
            return 1;
        }
        setvbuf(mon.samples, NULL, _IOFBF, 8u << 20);
        fprintf(mon.lost, "time_ns,thread,cpu,kind,event,count\n");
        if (perm) {
            snprintf(path, sizeof(path), "%s_perm.bin", o.perf_out);
            FILE *pf = fopen(path, "wb");
            if (!pf || fwrite(perm, sizeof(*perm), pages, pf) != pages) {
                fprintf(stderr, "cannot write %s\n", path);
                return 1;
            }
            fclose(pf);
        }
        rings = calloc((size_t)o.threads, sizeof(*rings));
        if (o.perf_drop_all && (o.bpf_prog_fd = load_drop_all_prog()) < 0) {
            perror("BPF_PROG_LOAD (--perf-drop-all needs root)");
            return 1;
        }
    }

    struct shared sh = {
        .buf = buf,
        .perm = perm,
        .pages = pages,
        .hot_n = hot_n,
        .page_size = o.page_size,
        .lines_per_page = o.page_size / CACHE_LINE,
        .duration_ns = (uint64_t)(o.duration_s * 1e9),
        .write_mode = o.write_mode,
        .opts = &o,
    };
    zipf_init(&sh.zipf, pages, theta);

    struct worker *w = calloc((size_t)o.threads, sizeof(*w));
    int launched = 0;
    for (int t = 0; t < o.threads; t++) {
        w[t].sh = &sh;
        w[t].cpu = cpus[t];
        w[t].ring = rings ? &rings[t] : NULL;
        w[t].seed = o.seed * 0x9e3779b97f4a7c15ull + (uint64_t)t + 1;
        if (pthread_create(&w[t].tid, NULL, run_worker, &w[t])) {
            perror("pthread_create");
            break;
        }
        launched++;
    }
    while (__atomic_load_n(&sh.ready, __ATOMIC_ACQUIRE) + __atomic_load_n(&sh.failed, __ATOMIC_ACQUIRE) <
           launched)
        sched_yield();
    if (launched < o.threads || sh.failed) {
        sh.abort = 1;
        sh.start = 1;
        for (int t = 0; t < launched; t++)
            pthread_join(w[t].tid, NULL);
        fprintf(stderr, "worker setup failed\n");
        return 1;
    }

    if (rings) {
        mon.rings = rings;
        mon.nrings = launched;
        mon.cpus = cpus;
        mon.lo = (uint64_t)(uintptr_t)buf;
        mon.hi = mon.lo + len;
        mon.keep_all = o.perf_keep_all;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        if (monitor_cpu >= 0) {
            cpu_set_t set;
            CPU_ZERO(&set);
            CPU_SET(monitor_cpu, &set);
            pthread_attr_setaffinity_np(&attr, sizeof(set), &set);
        }
        if (pthread_create(&mon.tid, &attr, run_monitor, &mon)) {
            perror("pthread_create(monitor)");
            return 1;
        }
        pthread_attr_destroy(&attr);
    }

    uint64_t t_start = rings ? perf_clock_now(rings[0].mp) : 0;
    static struct tstat aux0[MAX_TASKS], aux1[MAX_TASKS];
    int naux0 = task_snapshot(w, launched, aux0);
    sh.start = 1;

    uint64_t total = 0, hot = 0, max_ns = 0, sink = 0;
    for (int t = 0; t < launched; t++) {
        pthread_join(w[t].tid, NULL);
        total += w[t].accesses;
        hot += w[t].hot_accesses;
        sink += w[t].sink;
        if (w[t].runtime_ns > max_ns)
            max_ns = w[t].runtime_ns;
    }
    uint64_t t_end = rings ? perf_clock_now(rings[0].mp) : 0;
    int naux1 = task_snapshot(w, launched, aux1);
    g_naux = aux_by_name(aux0, naux0, aux1, naux1, g_aux_by, &g_aux_cpu_s);

    double secs = (double)max_ns / 1e9;
    g_accesses = total;
    g_runtime_s = secs;
    printf("result: accesses=%" PRIu64 " runtime_s=%.3f maccesses_per_s=%.2f"
           " observed_hot_access=%.2f%% sink=%" PRIu64 " aux_cpu_s=%.2f\n",
           total, secs, (double)total / secs / 1e6, 100.0 * (double)hot / (double)total, sink,
           g_aux_cpu_s);
    printf("aux_cpu_by_thread:");
    for (int i = 0; i < g_naux; i++)
        printf(" %s=%.2f", g_aux_by[i].comm, g_aux_by[i].ticks);
    printf("\n");

    if (rings) {
        mon.stop = 1;
        pthread_join(mon.tid, NULL);
        fclose(mon.samples);
        fclose(mon.lost);
        for (int e = 0; e < o.nev; e++) {
            uint64_t s = 0, l = 0, th = 0, c = 0, out = 0;
            for (int t = 0; t < launched; t++) {
                out += rings[t].outside[e];
                s += rings[t].samples[e];
                l += rings[t].lost[e];
                th += rings[t].throttles[e];
                c += rings[t].count[e];
            }
            double unacc = c ? 100.0 * (1.0 - (double)(o.perf_keep_all ? s : s + out) * (double)o.ev_period[e] / (double)c) : 0.0;
            printf("perf: %-10s period=%" PRIu64 " count=%" PRIu64 " samples=%" PRIu64 " outside_buf=%" PRIu64
                   "%s lost=%" PRIu64 " throttles=%" PRIu64 " unaccounted=%.1f%%\n",
                   ev_names[e], o.ev_period[e], c, s, out, o.perf_keep_all ? "" : " (dropped)", l, th, unacc);
            if (unacc > 5.0 && !o.perf_drop_all)
                fprintf(stderr, "warning: %s lost %.1f%% of samples without LOST records\n", ev_names[e], unacc);
        }
        snprintf(path, sizeof(path), "%s_meta.json", o.perf_out);
        write_meta(path, &o, &sh, len, theta, expected_hot, w, launched, monitor_cpu, t_start, t_end, rings);
        for (int t = 0; t < launched; t++) {
            munmap(rings[t].mp, rings[t].mmap_len);
            for (int e = 0; e < o.nev; e++)
                close(rings[t].fd[e]);
        }
        free(rings);
    }

    free(w);
    free(perm);
    free(cpus);
    munmap(raw, map_len);
    return 0;
}
