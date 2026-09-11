// C++11 contract test for the shared zoning helpers: unprefaulted capacity,
// prefix registration, and command-line extraction.
// Build: g++ -std=c++11 -O2 -Wall -Wextra -pthread -I<common> zones_test.cpp -ldl
#include "regent_regions/zones.h"
#include <cassert>
#include <functional>
#include <sys/mman.h>
#include <unistd.h>

using namespace workload_regions;

static unsigned calls;
static size_t last_size;
static int register_fake(void *base, size_t size, uint32_t id, const char *,
                         uint64_t budget) {
    assert(id == 3 && budget == 2 * migration_bytes);
    assert(reinterpret_cast<uintptr_t>(base) % migration_bytes == 0);
    ++calls;
    last_size = size;
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

static bool page_resident(const void *p) {
    unsigned char state;
    long page = sysconf(_SC_PAGESIZE);
    void *aligned = reinterpret_cast<void *>(
        reinterpret_cast<uintptr_t>(p) / page * page);
    return mincore(aligned, page, &state) == 0 && (state & 1);
}

static void test_prefix_registration() {
    // Ten pages of capacity, only the first 2.5 written by the "workload".
    Buffer<double> b;
    b.use_mapping();
    const size_t capacity = 5 * migration_bytes / sizeof(double);
    b.resize(capacity, false);
    assert(b.mapped_bytes() == 5 * migration_bytes);
    assert(!page_resident(b.data()));
    const size_t active = migration_bytes / sizeof(double) * 5 / 2;
    b[0] = 1.5;
    b[active - 1] = -2.25;
    Region r{"matrix", "simple_frequency", 2 * migration_bytes};
    b.register_prefix_with(register_fake, 3, r, active);
    assert(calls == 1 && last_size == 3 * migration_bytes);
    assert(b.registered_bytes() == 3 * migration_bytes);
    assert(b[0] == 1.5 && b[active - 1] == -2.25);
    // Every page of the registered prefix is resident; the tail is untouched.
    for (size_t off = 0; off < 3 * migration_bytes; off += 4096)
        assert(page_resident(reinterpret_cast<char *>(b.data()) + off));
    assert(!page_resident(reinterpret_cast<char *>(b.data()) +
                          4 * migration_bytes));
    throws([&] { b.register_prefix_with(register_fake, 3, r, active); });
    Buffer<int> small;
    small.use_mapping();
    small.resize(4);
    throws([&] { small.register_prefix_with(register_fake, 3, r, 5); });
    throws([&] { small.register_prefix_with(register_fake, 3, r, 0); });
}

static std::vector<std::string> args_after(std::vector<std::string> argv,
                                           ZoneConfig &config) {
    std::vector<char *> raw;
    for (std::string &s : argv)
        raw.push_back(&s[0]);
    raw.push_back(nullptr);
    int argc = static_cast<int>(argv.size());
    config = ZoneConfig::extract(argc, raw.data(), {"alpha", "beta"});
    return std::vector<std::string>(raw.begin(), raw.begin() + argc);
}

static void test_extraction() {
    unsetenv("REGENT_REGION_MODE");
    ZoneConfig config;
    auto rest = args_after({"prog", "-g", "10", "--region-layout-only", "-n",
                            "2", "--warmups", "3"},
                           config);
    assert(rest == std::vector<std::string>({"prog", "-g", "10", "-n", "2"}));
    assert(config.layout && !config.application && config.warmups == 3);
    rest = args_after({"prog", "-v"}, config);
    assert(rest.size() == 2 && !config.mapped() && config.warmups == 0);
    throws([&] { args_after({"prog", "--warmups"}, config); });
    throws([&] { args_after({"prog", "--warmups", "-1"}, config); });
    throws([&] { args_after({"prog", "--warmups", "1", "--warmups", "2"},
                            config); });
    throws([&] { args_after({"prog", "--app-region", "alpha:evolve:0"},
                            config); });
    throws([&] {
        args_after({"prog", "--app-regions", "--region-layout-only"}, config);
    });
    // Application mode: both zones exactly once, then runtime checks.
    setenv("REGENT_REGION_MODE", "application", 1);
    setenv("REGENT_FAST_MEMORY", "4M", 1);
    throws([&] { args_after({"prog", "-v"}, config); });
    throws([&] {
        args_after({"prog", "--app-regions", "--app-region", "alpha:evolve:0"},
                   config);
    });
    throws([&] {
        args_after({"prog", "--app-regions", "--app-region", "alpha:evolve:0",
                    "--app-region", "beta:evolve:0", "--app-region",
                    "gamma:evolve:0"},
                   config);
    });
    throws([&] {
        args_after({"prog", "--app-regions", "--app-region", "alpha:evolve:2M",
                    "--app-region", "beta:evolve:4M"},
                   config);
    });
    // Symbol absent in this test binary: resolution must fail last.
    throws([&] {
        args_after({"prog", "--app-regions", "--app-region", "beta:evolve:2M",
                    "--app-region", "alpha:simple_frequency:2M"},
                   config);
    });
    unsetenv("REGENT_REGION_MODE");
    unsetenv("REGENT_FAST_MEMORY");
}

int main() {
    test_prefix_registration();
    test_extraction();
    return 0;
}
