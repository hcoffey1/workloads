#ifndef MERCI_BASELINE_OPTIONS_H
#define MERCI_BASELINE_OPTIONS_H

#include "evaluator.h"
#include "regent_regions/regions.h"
#include <climits>
#include <iomanip>
#include <set>

struct BaselineOptions {
    std::string dataset;
    int cores = std::max(1u, std::thread::hardware_concurrency());
    int repeats = 5;
    int warmups = 0;
    bool application = false;
    bool layout = false;
    bool verify = false;
    bool seeded = false;
    uint32_t seed = 1;
    std::vector<workload_regions::Region> regions;
    workload_regions::RegisterFn registration = nullptr;

    static int count(const std::string &s, bool allow_zero = false) {
        uint64_t n = workload_regions::unsigned_number(s);
        if (n > INT_MAX || (!n && !allow_zero))
            throw std::runtime_error(
                "count must be a positive int (warmups may be zero)");
        return static_cast<int>(n);
    }

    BaselineOptions(int argc, const char **argv) {
        std::set<std::string> seen;
        for (int i = 1; i < argc; ++i) {
            std::string key(argv[i]);
            if (key == "--dataset")
                key = "-d";
            if (key != "--app-region" && !seen.insert(key).second)
                throw std::runtime_error("duplicate option: " + key);
            if (key == "--app-regions")
                application = true;
            else if (key == "--region-layout-only")
                layout = true;
            else if (key == "--verify")
                verify = true;
            else {
                if (i + 1 == argc)
                    throw std::runtime_error("missing value for " + key);
                std::string value(argv[++i]);
                if (key == "-d")
                    dataset = value;
                else if (key == "-c")
                    cores = count(value);
                else if (key == "-r")
                    repeats = count(value);
                else if (key == "--warmups")
                    warmups = count(value, true);
                else if (key == "--shuffle-seed") {
                    uint64_t n = workload_regions::unsigned_number(value);
                    if (n > UINT32_MAX)
                        throw std::runtime_error("shuffle seed exceeds uint32");
                    seed = static_cast<uint32_t>(n);
                    seeded = true;
                } else if (key == "--app-region") {
                    regions.push_back(workload_regions::parse_region(value));
                } else
                    throw std::runtime_error("unknown option: " + key);
            }
        }
        if (dataset.empty() || dataset.find('/') != std::string::npos ||
            dataset == "." || dataset == "..")
            throw std::runtime_error("provide a dataset name with -d");
        if (application && layout)
            throw std::runtime_error(
                "choose --app-regions or --region-layout-only");
        if (layout && dlsym(RTLD_DEFAULT, "regent_register_region"))
            throw std::runtime_error("layout-only requires no REGENT preload");
        if (!application && !regions.empty())
            throw std::runtime_error("--app-region requires --app-regions");
        if (application) {
            std::vector<workload_regions::Region> ordered;
            for (const char *name : {"embedding", "output"}) {
                for (const auto &r : regions)
                    if (r.name == name)
                        ordered.push_back(r);
                if (ordered.size() !=
                    (std::string(name) == "embedding" ? 1u : 2u))
                    throw std::runtime_error(
                        "declare embedding and output exactly once");
            }
            if (regions.size() != 2)
                throw std::runtime_error("unknown or duplicate region; "
                                         "expected embedding and output");
            regions = ordered;
            registration = workload_regions::resolve(regions);
        } else {
            const char *mode = std::getenv("REGENT_REGION_MODE");
            if (mode && std::string(mode) == "application")
                throw std::runtime_error(
                    "application runtime requires --app-regions");
        }
        if (application || layout)
            seeded = true;
    }
    bool mapped() const { return application || layout; }
};

inline void validate_queries(const QueryData &qd, int features) {
    if (qd.query.empty() || qd.query.size() > INT_MAX)
        throw std::runtime_error("query count must be nonzero and fit int");
    for (const auto &query : qd.query) {
        if (query.empty())
            throw std::runtime_error("empty query");
        for (int id : query)
            if (id < 0 || id > features) // ids are 1-based: 1..features
                throw std::runtime_error(
                    "query feature outside embedding table");
    }
}

inline void verify_baseline(const Baseline &ep, const QueryData &qd) {
    size_t row = 0;
    double checksum = 0;
    for (const auto &partition : qd.partitioned_query) {
        for (const auto &query : partition) {
            for (int dim = 0; dim < EMBEDDING_DIM; ++dim) {
                float expected = 0;
                for (int id : query)
                    expected += ep.embedding_table[id][dim];
                float actual = ep.qres[row][dim];
                if (std::abs(actual - expected) >
                    1e-5f * std::max(1.0f, std::abs(expected)))
                    throw std::runtime_error(
                        "baseline verification failed at row " +
                        std::to_string(row));
                checksum += actual;
            }
            ++row;
        }
    }
    cout << "MERCI_VERIFY {\"rows\":" << row
         << ",\"checksum\":" << std::setprecision(17) << checksum << "}"
         << endl;
}

inline void baseline_manifest(const BaselineOptions &options,
                              const Baseline &ep, const QueryData &qd,
                              const std::string &input) {
    using workload_regions::json_string;
    uint64_t query_bytes = 0, partition_bytes = 0;
    uint64_t query_order_hash = UINT64_C(14695981039346656037);
    auto hash_word = [&](uint64_t word) {
        for (int i = 0; i < 8; ++i) {
            query_order_hash ^= (word >> (8 * i)) & 255;
            query_order_hash *= UINT64_C(1099511628211);
        }
    };
    // Capacities describe payload storage, excluding allocator overhead and
    // outer descriptors. These are intentionally not managed region bytes.
    for (const auto &q : qd.query) {
        query_bytes += q.capacity() * sizeof(int);
        hash_word(q.size());
        for (int id : q)
            hash_word(id);
    }
    for (const auto &part : qd.partitioned_query)
        for (const auto &q : part)
            partition_bytes += q.capacity() * sizeof(int);
    const char *numa = std::getenv("NUMA_PLACEMENT");
    cout << "REGENT_ZONE_MANIFEST "
            "{\"schema_version\":1,\"workload\":\"merci_baseline\",\"mode\":"
         << json_string(options.application ? "application" : "layout")
         << ",\"input\":" << json_string(input)
         << ",\"shuffle_seed\":" << options.seed
         << ",\"threads\":" << options.cores
         << ",\"query_order_fnv1a64\":" << query_order_hash
         << ",\"repeats\":" << options.repeats
         << ",\"warmups\":" << options.warmups
         << ",\"verification\":" << (options.verify ? "true" : "false")
         << ",\"numa_placement_requested\":"
         << json_string(numa ? numa : "unspecified")
         << ",\"unmanaged_query_payload_bytes\":" << query_bytes
         << ",\"unmanaged_partition_payload_bytes\":" << partition_bytes
         << ",\"unmanaged\":[\"query descriptors\",\"cache "
            "flush\",\"thread/runtime storage\"],\"zones\":[";
    for (unsigned i = 0; i < 2; ++i) {
        const auto &buffer = i == 0 ? ep.embedding_table : ep.qres;
        if (i)
            cout << ',';
        cout << "{\"name\":" << json_string(i == 0 ? "embedding" : "output")
             << ",\"buffer\":"
             << json_string(i == 0 ? "embedding_table" : "qres")
             << ",\"application_id\":" << i << ",\"runtime_id\":" << i + 1
             << ",\"base\":" << reinterpret_cast<uintptr_t>(buffer.data())
             << ",\"logical_bytes\":" << buffer.logical_bytes()
             << ",\"mapped_bytes\":" << buffer.mapped_bytes()
             << ",\"registered_bytes\":" << buffer.registered_bytes()
             << ",\"policy\":"
             << (options.application ? json_string(options.regions[i].policy)
                                     : "null")
             << ",\"fast_bytes\":"
             << (options.application ? std::to_string(options.regions[i].budget)
                                     : "null")
             << '}';
    }
    cout << "]}" << endl;
}

#endif
