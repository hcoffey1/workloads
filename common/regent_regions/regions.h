#ifndef WORKLOAD_REGENT_REGIONS_H
#define WORKLOAD_REGENT_REGIONS_H

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <type_traits>
#include <unistd.h>
#include <vector>

namespace workload_regions {

// Public REGENT ABI migration unit; unrelated to profiling alignment.
static const size_t migration_bytes = 2 * 1024 * 1024;
typedef int (*RegisterFn)(void *, size_t, uint32_t, const char *, uint64_t);

inline uint64_t unsigned_number(const std::string &s) {
    if (s.empty())
        throw std::runtime_error("expected an unsigned integer");
    uint64_t result = 0;
    for (char c : s) {
        if (c < '0' || c > '9' ||
            result > (UINT64_MAX - static_cast<unsigned>(c - '0')) / 10)
            throw std::runtime_error("invalid or overflowing integer: " + s);
        result = result * 10 + (c - '0');
    }
    return result;
}

inline uint64_t size_bytes(std::string s) {
    uint64_t scale = 1;
    if (!s.empty()) {
        const std::string units = "KMGT";
        size_t unit = units.find(s.back());
        if (unit != std::string::npos) {
            scale = uint64_t(1) << (10 * (unit + 1));
            s.pop_back();
        }
    }
    uint64_t n = unsigned_number(s);
    if (n > UINT64_MAX / scale)
        throw std::runtime_error("size overflows");
    return n * scale;
}

inline size_t round_storage(size_t bytes) {
    if (!bytes || bytes > SIZE_MAX - (migration_bytes - 1))
        throw std::runtime_error("empty or overflowing region storage");
    return (bytes + migration_bytes - 1) / migration_bytes * migration_bytes;
}

inline std::string json_string(const std::string &s) {
    std::string out = "\"";
    const char *hex = "0123456789abcdef";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += c;
        } else if (c < 32) {
            out += "\\u00";
            out += hex[c >> 4];
            out += hex[c & 15];
        } else {
            out += c;
        }
    }
    return out + '"';
}

struct Region {
    std::string name;
    std::string policy;
    uint64_t budget;
};

inline Region parse_region(const std::string &s) {
    size_t a = s.find(':'), b = s.find(':', a == std::string::npos ? a : a + 1);
    if (a == std::string::npos || b == std::string::npos ||
        s.find(':', b + 1) != std::string::npos)
        throw std::runtime_error("region must be name:policy:fast-bytes");
    Region r{s.substr(0, a), s.substr(a + 1, b - a - 1),
             size_bytes(s.substr(b + 1))};
    if (r.policy != "simple_frequency" && r.policy != "evolve")
        throw std::runtime_error("unqualified application policy: " + r.policy);
    if (r.budget % migration_bytes)
        throw std::runtime_error("region budget must be a multiple of 2M");
    return r;
}

inline RegisterFn resolve(const std::vector<Region> &regions) {
    const char *mode = std::getenv("REGENT_REGION_MODE");
    if (!mode || std::string(mode) != "application")
        throw std::runtime_error(
            "--app-regions requires REGENT_REGION_MODE=application");
    for (const char *key : {"REGENT_NO_CLUSTERING", "REGENT_CLUSTER_CONFIG",
                            "REGENT_REBALANCER"}) {
        const char *value = std::getenv(key);
        if (value && *value)
            throw std::runtime_error(
                std::string("unset incompatible setting: ") + key);
    }
    const char *total_setting = std::getenv("REGENT_FAST_MEMORY");
    if (!total_setting)
        throw std::runtime_error(
            "--app-regions requires explicit REGENT_FAST_MEMORY");
    uint64_t total = 0;
    for (const Region &r : regions) {
        if (r.budget > UINT64_MAX - total)
            throw std::runtime_error("region budget sum overflows");
        total += r.budget;
    }
    if (total > size_bytes(total_setting))
        throw std::runtime_error("region budgets exceed REGENT_FAST_MEMORY");
    void *symbol = dlsym(RTLD_DEFAULT, "regent_register_region");
    if (!symbol)
        throw std::runtime_error(
            "regent_register_region unavailable; preload REGENT");
    return reinterpret_cast<RegisterFn>(symbol);
}

// Fixed mapped storage for trivial array elements, with the legacy vector path
// retained. Hot indexing always uses data_; no mode branch enters the kernel.
template <class T> class Buffer {
    static_assert(std::is_trivial<T>::value, "region elements must be trivial");
    std::vector<T> legacy_;
    T *data_ = nullptr;
    size_t count_ = 0;
    size_t mapped_bytes_ = 0;
    bool mapped_ = false;
    bool registered_ = false;

  public:
    Buffer() = default;
    Buffer(const Buffer &) = delete;
    Buffer &operator=(const Buffer &) = delete;
    ~Buffer() {
        // No unregister ABI: runtime workers may outlive application objects.
        if (mapped_bytes_ && !registered_)
            munmap(data_, mapped_bytes_);
    }
    void use_mapping() {
        if (data_)
            throw std::runtime_error("cannot change allocated buffer layout");
        mapped_ = true;
    }
    void resize(size_t count) {
        if (count > SIZE_MAX / sizeof(T))
            throw std::runtime_error("element count overflows");
        if (!mapped_) {
            legacy_.resize(count);
            data_ = legacy_.data();
            count_ = count;
            return;
        }
        if (data_) {
            if (count != count_)
                throw std::runtime_error("mapped buffer size cannot change");
            return;
        }
        const size_t bytes = round_storage(count * sizeof(T));
        if (bytes > SIZE_MAX - migration_bytes)
            throw std::runtime_error("mapping size overflows");
        void *raw =
            mmap(nullptr, bytes + migration_bytes, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (raw == MAP_FAILED)
            throw std::runtime_error("region mmap failed");
        uintptr_t start = reinterpret_cast<uintptr_t>(raw);
        size_t prefix =
            (migration_bytes - start % migration_bytes) % migration_bytes;
        void *aligned = reinterpret_cast<void *>(start + prefix);
        if (prefix)
            munmap(raw, prefix);
        munmap(reinterpret_cast<void *>(start + prefix + bytes),
               migration_bytes - prefix);
        if (madvise(aligned, bytes, MADV_HUGEPAGE) != 0) {
            munmap(aligned, bytes);
            throw std::runtime_error("MADV_HUGEPAGE failed");
        }
        // Write every base page, including padding, before registration. This
        // also avoids admitting the shared zero page for untouched output rows.
        std::memset(aligned, 0, bytes);
        data_ = static_cast<T *>(aligned);
        for (size_t i = 0; i < count; ++i)
            ::new (static_cast<void *>(data_ + i)) T;
        count_ = count;
        mapped_bytes_ = bytes;
    }
    void register_with(RegisterFn fn, uint32_t id, const Region &region) {
        if (!mapped_bytes_ || registered_)
            throw std::runtime_error(
                "buffer must be mapped and registered once");
        if (fn(data_, mapped_bytes_, id, region.policy.c_str(),
               region.budget) != 0)
            throw std::runtime_error("registration failed for " + region.name);
        registered_ = true;
    }
    T &operator[](size_t i) { return data_[i]; }
    const T &operator[](size_t i) const { return data_[i]; }
    T *data() { return data_; }
    const T *data() const { return data_; }
    size_t size() const { return count_; }
    size_t logical_bytes() const { return count_ * sizeof(T); }
    size_t mapped_bytes() const { return mapped_bytes_; }
    size_t registered_bytes() const { return registered_ ? mapped_bytes_ : 0; }
};

} // namespace workload_regions
#endif
