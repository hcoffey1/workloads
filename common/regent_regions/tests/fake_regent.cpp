// Fake REGENT registration library for hardware-free workload tests.
// Build: g++ -std=c++11 -shared -fPIC fake_regent.cpp -o fake.so
// Aborts on an unaligned, unpadded, or not fully resident range, or on ids
// that arrive out of order. A zone may register several ranges with the same
// id. FAKE_FAIL_ID=N makes the first call for id N fail. At exit every
// accepted mapping must still be resident (no unregister ABI exists).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

struct Mapping {
    void *base;
    size_t size;
    unsigned id;
};
static std::vector<Mapping> *mappings;
static unsigned last_id;
static bool any;

static bool resident(void *base, size_t size) {
    long page = sysconf(_SC_PAGESIZE);
    std::vector<unsigned char> state(size / page);
    if (mincore(base, size, state.data()))
        return false;
    for (unsigned char value : state)
        if (!(value & 1))
            return false;
    return true;
}

extern "C" int regent_register_region(void *base, size_t size, uint32_t id,
                                      const char *policy, uint64_t budget) {
    if ((any && id < last_id) || (!any && id != 0) ||
        reinterpret_cast<uintptr_t>(base) % (2 * 1024 * 1024) ||
        size % (2 * 1024 * 1024) || !size || !resident(base, size))
        std::abort();
    any = true;
    last_id = id;
    std::printf("FAKE_REGISTER "
                "{\"id\":%u,\"base\":%llu,\"size\":%zu,\"budget\":%llu,"
                "\"policy\":\"%s\"}\n",
                id, (unsigned long long)reinterpret_cast<uintptr_t>(base), size,
                (unsigned long long)budget, policy);
    std::fflush(stdout);
    const char *fail = std::getenv("FAKE_FAIL_ID");
    if (fail && std::atoi(fail) == int(id))
        return -1;
    if (!mappings)
        mappings = new std::vector<Mapping>;
    mappings->push_back(Mapping{base, size, id});
    return 0;
}

__attribute__((destructor)) static void check_lifetime() {
    if (!mappings)
        return;
    for (const Mapping &m : *mappings) {
        if (!resident(m.base, m.size))
            std::abort();
        std::printf("FAKE_RETAINED %u\n", m.id);
    }
    std::fflush(stdout);
}
