#ifndef MERCI_UTILS_H
#define MERCI_UTILS_H

#include <algorithm>
#include <array>
#include <atomic>
#include <bitset>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <malloc.h>
#include <mutex>
#include <new>
#include <omp.h>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace std;
using namespace std::chrono;

// TODO: support various embedding dimension, we only support embedding dimension 64 for now.
#define EMBEDDING_DIM 64    //dimension of each embedding vector
#define CACHE_FLUSH_PARAM 12
#define PARTITION_SIZE 128   //number of features in each partition
#define DEBUG 0           //0: off, 1: on (print counters)

struct TInfo {
    steady_clock::time_point tstart; // 8B
    steady_clock::time_point tend; // 8B
    int qbase;
};

uint64_t convertTime(steady_clock::time_point start, steady_clock::time_point end) {
    long long nanoseconds = chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    return nanoseconds; 
}

class CustomBarrier {
public:
    std::atomic<int> bar = 0; // Counter of threads, faced barrier.
    std::atomic<int> passed = 0; // Number of barriers, passed by all threads.
public:

    void barrier_wait(int P)
    {
        int passed_old = passed.load(std::memory_order_relaxed);

        if(bar.fetch_add(1) == (P - 1))
        {
            // The last thread, faced barrier.
            bar = 0;
            // Synchronize and store in one operation.
            passed.store(passed_old + 1, std::memory_order_release);
        }
        else
        {
            // Not the last thread. Wait others.
            while(passed.load(std::memory_order_relaxed) == passed_old) {__builtin_ia32_pause();};
            // Need to synchronize cache with other threads, passed barrier.
            std::atomic_thread_fence(std::memory_order_acquire);
        }
    }
};

volatile float *v;
volatile double vval;
void __attribute__((optimize("O2"))) cacheFlush() {
    #if DEBUG
    const unsigned long bigger_than_cachesize = (unsigned long) 1 * 1024 * 1024;
    #else
    const unsigned long bigger_than_cachesize = (unsigned long) (CACHE_FLUSH_PARAM * 1024 * 1024);
    #endif
    float *p = new float[bigger_than_cachesize];
    v = p;
    #pragma omp parallel for schedule(static)
    for(unsigned long i = 0; i < bigger_than_cachesize; i++) {
       p[i] = 1;
    }
    size_t core_count = thread::hardware_concurrency();
    vector<array<float, 16>> myf(core_count);
    for(size_t i=0; i<core_count; i++) {
        for(int j=0; j<16; j++) {
            //myf[i][j] = 0.0f;
            myf[i].at(j) = 0.0f;
        }
    }
    #pragma omp parallel for schedule(static)
    for(size_t i = 0; i < bigger_than_cachesize; i++) {
        int tid = omp_get_thread_num();
        //myf[tid][0]+= p[i];
        myf[tid].at(0)+= p[i];
    }
    for(size_t i=0; i<core_count; i++) {
        // vval += myf[i][0];
        vval += myf[i].at(0);
    }
    delete[] p;
}


class QueryData {
public:
    vector< vector<int> > query;
    vector<vector<vector<int>>> partitioned_query; // Core x Query Per Core

    int total_query_feature_cnt; //total number of items in all queries (SOT)
    // int total_chunks;

    QueryData(ifstream &testFile, bool baseline = false,
              const uint32_t *shuffle_seed = nullptr)
        : total_query_feature_cnt(0) {

        string line;
        while (getline(testFile, line)) { //read line by line
            if(line.empty())
                continue; //skip empty line (to be extra safe)
            vector<int> single_query;
            int item_id;
            stringstream iss(line);
            if(baseline) {
                int weight=0;            
                iss >> weight;
                if (weight <= 0) {
                    cout << "TESTSET ERROR: Weight of test query <= 0" << endl;
                    exit(1);
                }

                while (iss >> item_id) {
                    single_query.push_back(item_id);
                    total_query_feature_cnt += weight;
                }
                for (int i=0; i < weight; i++) //store (weight) tiems (i.e., weight == repetition count)
                    query.push_back(single_query); //no need to sort each query by remapped id, since its already done during convert stage
            }
            else {
                while (iss >> item_id) {
                    single_query.push_back(item_id);
                    ++total_query_feature_cnt;
                }
                query.push_back(single_query);
            }
        }

        //random_shuffle(query.begin(), query.end()); //random shuffle to scatter duplicate queries
        std::shuffle(
            query.begin(), query.end(),
            std::mt19937(
                shuffle_seed
                    ? *shuffle_seed
                    : std::random_device()())); // random shuffle to scatter
                                                // duplicate queries

        cout << "================== QUERY INFO ==================" << endl;
        cout << "# of Queries                   : " << query.size() << endl;
        cout << "Sum of Transaction Length (SOT): " << total_query_feature_cnt << endl;
        cout << "Average Transaction Length     : " << (double)total_query_feature_cnt/query.size() << endl;
        cout << "================================================" << endl << endl;
    }

    //partition query by # of threads
    void partition(size_t core_count) {
        int query_per_core = query.size() / core_count;
        auto last_queries = query.size() % core_count;
        // partitioned_query.push_back(vector<vector<int>>());
        for(size_t i=0; i<core_count; i++) {
            int base, amount = 0;
            vector<vector<int>> pq;
            if(i < last_queries) {
                amount = query_per_core + 1;
                base = i * (query_per_core+1);
            }
            else {
                amount = query_per_core;
                base = last_queries * (query_per_core+1) + (i-last_queries) * query_per_core;
            }
            copy(query.begin() + base, query.begin() + base + amount, back_inserter(pq));
            partitioned_query.push_back(pq);
        }
    }
};

inline void eval_event(const char *phase, int trial,
                       steady_clock::time_point when) {
    cout << "MERCI_EVENT {\"phase\":\"" << phase << "\",\"trial\":" << trial
         << ",\"monotonic_ns\":"
         << duration_cast<nanoseconds>(when.time_since_epoch()).count() << "}"
         << endl;
}

struct EvalControl {
    int warmups = 0;
    bool trace = false;
    std::function<void()> verify;
};

template <class T>
void eval(T &ep, QueryData &qd, const size_t core_count, vector<thread> &t,
          int repeat, string name, const EvalControl *control = nullptr) {
    double total_time_accum = 0;
    for (int k = control ? -control->warmups : 0; k < repeat; k++) {
        double time_accum = 0;
        if (control && control->trace)
            eval_event("reset_begin", k, steady_clock::now());
        ep.init(qd.query.size());
        ep.setqbase(qd.partitioned_query);
        if (control && control->trace)
            eval_event("reset_end", k, steady_clock::now());
        cacheFlush();
        if (control && control->trace)
            eval_event("cache_flush_end", k, steady_clock::now());
        if(core_count > 0) {
            for(size_t i=0; i<core_count; i++) {
                t[i] = thread(&T::process, &ep, ref(qd.partitioned_query[i]), i);
//                cpu_set_t cpuset;
//                CPU_ZERO(&cpuset);
//                CPU_SET(i, &cpuset);
//                int rc = pthread_setaffinity_np(t[i].native_handle(),sizeof(cpu_set_t), &cpuset);
            }
            for(size_t i=0; i<core_count; i++)
                t[i].join();
        }
        else
            assert(false);
        if (control && control->trace) {
            eval_event("kernel_begin", k, ep.start);
            eval_event("kernel_end", k, ep.end);
        }
        if (control && control->verify)
            control->verify();
        time_accum += ((double)convertTime(ep.start, ep.end)) / 1000 / 1000;

        #if DEBUG
        // Result Verification
        double rsum = 0.0;
        auto idx = 0;
        for(size_t i=0; i<qd.partitioned_query.size(); i++){
            auto qsize = qd.partitioned_query[i].size();
            for(size_t j=0; j<qsize; j++, idx++)
                for(int k=0; k<EMBEDDING_DIM; k++)
                    rsum += ep.qres[idx][k];
        }
        cout << "Result : " << rsum << endl;
        #endif
        cout << (k < 0 ? "WARMUP # " : "REPEAT # ") << (k < 0 ? -k : k) << " "
             << name << " Total time : " << time_accum << " ms" << endl;
        if (k >= 0)
            total_time_accum += time_accum;
    }
    cout << endl;
    cout << "\n========= " << name << " RESULT =========" << endl;
    cout << "Average Time: " << total_time_accum/repeat << " ms" << endl;
    cout << "================================" << endl;
}

#endif
