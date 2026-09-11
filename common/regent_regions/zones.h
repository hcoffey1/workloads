#ifndef WORKLOAD_REGENT_ZONES_H
#define WORKLOAD_REGENT_ZONES_H

// Shared opt-in zoning configuration for workloads whose own command line is
// not ours to redesign (getopt kernels, argument-less NPB binaries). The
// options below are extracted from argv before the workload parses it, so a
// legacy invocation is untouched and a zoned one only adds these flags:
//
//   --app-regions --app-region NAME:POLICY:BYTES ...   register declared zones
//   --region-layout-only                               same layout, no runtime
//   --warmups N                                        excluded extra trials
//
// A zone may span several buffers; each is registered with the zone's id and
// whole budget (registration resets the budget, it does not accumulate).

#include "regions.h"

#include <chrono>
#include <iostream>
#include <set>

namespace workload_regions {

struct ZoneConfig {
    bool application = false;
    bool layout = false;
    int warmups = 0;
    // Ordered like the names passed to extract(); index == application id.
    std::vector<Region> regions;
    RegisterFn registration = nullptr;

    bool mapped() const { return application || layout; }

    // Removes recognised options from argv (argc is updated) and validates
    // them against the workload's zone names. Everything else is left in
    // place for the workload's own parser.
    static ZoneConfig extract(int &argc, char **argv,
                              const std::vector<std::string> &names) {
        ZoneConfig config;
        std::vector<char *> rest;
        rest.push_back(argv[0]);
        std::set<std::string> seen;
        for (int i = 1; i < argc; ++i) {
            std::string key(argv[i]);
            if ((key == "--app-regions" || key == "--region-layout-only" ||
                 key == "--warmups") &&
                !seen.insert(key).second)
                throw std::runtime_error("duplicate option: " + key);
            if (key == "--app-regions")
                config.application = true;
            else if (key == "--region-layout-only")
                config.layout = true;
            else if (key == "--warmups" || key == "--app-region") {
                if (i + 1 == argc)
                    throw std::runtime_error("missing value for " + key);
                std::string value(argv[++i]);
                if (key == "--warmups") {
                    uint64_t n = unsigned_number(value);
                    if (n > INT32_MAX)
                        throw std::runtime_error("warmups must fit int");
                    config.warmups = static_cast<int>(n);
                } else
                    config.regions.push_back(parse_region(value));
            } else
                rest.push_back(argv[i]);
        }
        if (config.application && config.layout)
            throw std::runtime_error(
                "choose --app-regions or --region-layout-only");
        if (config.layout && dlsym(RTLD_DEFAULT, "regent_register_region"))
            throw std::runtime_error("layout-only requires no REGENT preload");
        if (!config.application && !config.regions.empty())
            throw std::runtime_error("--app-region requires --app-regions");
        if (config.application) {
            std::vector<Region> ordered;
            for (const std::string &name : names) {
                size_t found = ordered.size();
                for (const Region &r : config.regions)
                    if (r.name == name)
                        ordered.push_back(r);
                if (ordered.size() != found + 1)
                    throw std::runtime_error("declare zone exactly once: " +
                                             name);
            }
            if (config.regions.size() != names.size())
                throw std::runtime_error("unknown or duplicate zone declared");
            config.regions = ordered;
            config.registration = resolve(config.regions);
        } else {
            const char *mode = std::getenv("REGENT_REGION_MODE");
            if (mode && std::string(mode) == "application")
                throw std::runtime_error(
                    "application runtime requires --app-regions");
        }
        for (size_t i = 0; i < rest.size(); ++i)
            argv[i] = rest[i];
        argc = static_cast<int>(rest.size());
        argv[argc] = nullptr;
        return config;
    }
};

// One JSON line per marker: "<TAG>_EVENT {"phase":..,"trial":..,"monotonic_ns":..}"
// Negative trials are warmups; measured trials start at 0.
inline void zone_event(const char *tag, const char *phase, int trial,
                       std::chrono::steady_clock::time_point when =
                           std::chrono::steady_clock::now()) {
    std::cout << tag << "_EVENT {\"phase\":\"" << phase << "\",\"trial\":" << trial
              << ",\"monotonic_ns\":"
              << std::chrono::duration_cast<std::chrono::nanoseconds>(
                     when.time_since_epoch())
                     .count()
              << "}" << std::endl;
}

// Builds the REGENT_ZONE_MANIFEST line for zones with one or more buffers.
// schema_version 2: "zones[].buffers[]" carries per-range figures and the
// zone-level byte counts are their sums.
class Manifest {
    struct Range {
        std::string buffer;
        uintptr_t base;
        size_t logical, mapped, registered;
    };
    struct Zone {
        std::string name;
        std::vector<Range> ranges;
    };
    std::string workload_, mode_, extra_;
    std::vector<Zone> zones_;
    std::vector<std::string> unmanaged_;

  public:
    Manifest(const std::string &workload, const ZoneConfig &config)
        : workload_(workload),
          mode_(config.application ? "application" : "layout") {}
    void zone(const std::string &name) { zones_.push_back(Zone{name, {}}); }
    template <class T>
    void buffer(const std::string &name, const Buffer<T> &b) {
        zones_.back().ranges.push_back(
            Range{name, reinterpret_cast<uintptr_t>(b.data()),
                  b.logical_bytes(), b.mapped_bytes(), b.registered_bytes()});
    }
    // Buffers deliberately left outside every zone, with their sizes.
    void unmanaged(const std::string &name, uint64_t bytes) {
        unmanaged_.push_back("{\"name\":" + json_string(name) +
                             ",\"bytes\":" + std::to_string(bytes) + "}");
    }
    // Raw JSON members appended to the top-level object ("\"key\":value").
    void extra(const std::string &member) { extra_ += "," + member; }
    void print(const ZoneConfig &config) const {
        const char *numa = std::getenv("NUMA_PLACEMENT");
        std::cout << "REGENT_ZONE_MANIFEST {\"schema_version\":2,\"workload\":"
                  << json_string(workload_) << ",\"mode\":" << json_string(mode_)
                  << ",\"warmups\":" << config.warmups
                  << ",\"numa_placement_requested\":"
                  << json_string(numa ? numa : "unspecified") << extra_
                  << ",\"unmanaged\":[";
        for (size_t i = 0; i < unmanaged_.size(); ++i)
            std::cout << (i ? "," : "") << unmanaged_[i];
        std::cout << "],\"zones\":[";
        for (size_t i = 0; i < zones_.size(); ++i) {
            const Zone &z = zones_[i];
            size_t logical = 0, mapped = 0, registered = 0;
            std::cout << (i ? "," : "") << "{\"name\":" << json_string(z.name)
                      << ",\"application_id\":" << i
                      << ",\"runtime_id\":" << i + 1 << ",\"buffers\":[";
            for (size_t j = 0; j < z.ranges.size(); ++j) {
                const Range &r = z.ranges[j];
                logical += r.logical;
                mapped += r.mapped;
                registered += r.registered;
                std::cout << (j ? "," : "") << "{\"buffer\":"
                          << json_string(r.buffer) << ",\"base\":" << r.base
                          << ",\"logical_bytes\":" << r.logical
                          << ",\"mapped_bytes\":" << r.mapped
                          << ",\"registered_bytes\":" << r.registered << '}';
            }
            std::cout << "],\"logical_bytes\":" << logical
                      << ",\"mapped_bytes\":" << mapped
                      << ",\"registered_bytes\":" << registered
                      << ",\"policy\":"
                      << (config.application
                              ? json_string(config.regions[i].policy)
                              : "null")
                      << ",\"fast_bytes\":"
                      << (config.application
                              ? std::to_string(config.regions[i].budget)
                              : "null")
                      << '}';
        }
        std::cout << "]}" << std::endl;
    }
};

} // namespace workload_regions
#endif
