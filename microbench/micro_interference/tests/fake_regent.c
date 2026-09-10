/*
 * Fake REGENT registration API for hardware-free tests of the workload's
 * --app-regions path.
 *
 * LD_PRELOAD this and the benchmark's dlsym(RTLD_DEFAULT,
 * "regent_register_region") resolves here instead of to the real runtime, so a
 * test can assert exactly which ranges the workload declares without NUMA, PEBS
 * or a preloaded libarms_kernel.so.
 *
 * Each call appends one CSV line to $FAKE_REGENT_LOG:
 *   base,size,region_id,policy,fast_tier_bytes
 * Set FAKE_REGENT_FAIL_ON=<region_id> to return -1 for that id, to check the
 * workload aborts rather than running unmanaged.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

int regent_register_region(void *base, size_t size, uint32_t region_id,
                           const char *policy, uint64_t fast_tier_bytes) {
    const char *path = getenv("FAKE_REGENT_LOG");
    if (path && *path) {
        FILE *f = fopen(path, "a");
        if (f) {
            fprintf(f, "%p,%zu,%u,%s,%llu\n", base, size, region_id,
                    policy ? policy : "(null)",
                    (unsigned long long)fast_tier_bytes);
            fclose(f);
        }
    }
    const char *fail = getenv("FAKE_REGENT_FAIL_ON");
    if (fail && *fail && (uint32_t)strtoul(fail, NULL, 10) == region_id) {
        return -1;
    }
    return 0;
}
