#include "regent_regions/regions.h"
#include <array>
#include <cassert>
#include <functional>

using namespace workload_regions;
static unsigned calls;
static int register_fake(void *, size_t, uint32_t id, const char *,
                         uint64_t budget) {
    assert(id == 7 && budget == 4 * migration_bytes);
    ++calls;
    return 0;
}
static void throws(const std::function<void()> &fn) {
    bool caught = false;
    try {
        fn();
    } catch (const std::exception &) {
        caught = true;
    }
    assert(caught);
}
int main() {
    assert(size_bytes("0") == 0 && size_bytes("2M") == migration_bytes);
    for (const char *bad : {"", "-1", "+2", "2MB", "2MiB", " 2M", "2M ", "1.5G",
                            "18446744073709551616", "18446744073709551615T"})
        throws([&] { size_bytes(bad); });
    throws([] { round_storage(0); });
    throws([] { round_storage(SIZE_MAX); });
    throws([] { parse_region("x:arms:2M"); });
    throws([] { parse_region("x:simple_frequency:1M"); });
    Buffer<std::array<float, 64>> first;
    first.use_mapping();
    first.resize(8193);
    assert(first.logical_bytes() == 8193 * 256 &&
           first.mapped_bytes() == 2 * migration_bytes);
    assert(reinterpret_cast<uintptr_t>(first.data()) % migration_bytes == 0);
    first[8192][63] = 17;
    auto *original = first.data();
    first.resize(8193);
    assert(first.data() == original && first[8192][63] == 17);
    throws([&] { first.resize(8194); });
    throws([&] { first.use_mapping(); });
    Buffer<int> overflow;
    overflow.use_mapping();
    throws([&] { overflow.resize(SIZE_MAX); });
    void *released;
    {
        Buffer<int> b;
        b.use_mapping();
        b.resize(3);
        released = b.data();
    }
    unsigned char present;
    assert(mincore(released, sysconf(_SC_PAGESIZE), &present) == -1 &&
           errno == ENOMEM);
    void *retained;
    {
        Buffer<int> a, b;
        a.use_mapping();
        b.use_mapping();
        a.resize(1);
        b.resize(1);
        Region r{"shared", "simple_frequency", 4 * migration_bytes};
        a.register_with(register_fake, 7, r);
        b.register_with(register_fake, 7, r);
        assert(calls == 2 && a.registered_bytes() == migration_bytes);
        throws([&] { a.register_with(register_fake, 7, r); });
        retained = a.data();
    }
    assert(mincore(retained, sysconf(_SC_PAGESIZE), &present) == 0);
    Buffer<int> legacy;
    legacy.resize(3);
    legacy[1] = 42;
    legacy.resize(4);
    assert(legacy[1] == 42 && legacy.mapped_bytes() == 0);
}
