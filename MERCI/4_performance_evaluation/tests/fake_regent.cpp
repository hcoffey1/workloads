#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

struct Mapping {
    void *base;
    size_t size;
};
static Mapping mappings[2];
static unsigned calls;

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
    if (calls >= 2 || id != calls ||
        reinterpret_cast<uintptr_t>(base) % (2 * 1024 * 1024) ||
        size % (2 * 1024 * 1024) || !resident(base, size))
        std::abort();
    std::printf("FAKE_REGISTER "
                "{\"id\":%u,\"base\":%llu,\"size\":%zu,\"budget\":%llu,"
                "\"policy\":\"%s\"}\n",
                id, (unsigned long long)reinterpret_cast<uintptr_t>(base), size,
                (unsigned long long)budget, policy);
    ++calls;
    const char *fail = std::getenv("FAKE_FAIL_ID");
    if (fail && std::atoi(fail) == int(id))
        return -1;
    mappings[id] = {base, size};
    return 0;
}

__attribute__((destructor)) static void check_lifetime() {
    for (unsigned i = 0; i < 2; ++i) {
        if (mappings[i].base) {
            if (!resident(mappings[i].base, mappings[i].size))
                std::abort();
            std::printf("FAKE_RETAINED %u\n", i);
        }
    }
}
