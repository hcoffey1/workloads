#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# Page-granular Zipfian access microbenchmark. Skew is set either as a hot-set
# rule (ZIPF_BENCH_HOT_ACCESS of accesses go to the hottest ZIPF_BENCH_HOT_FRAC
# of pages; the Zipf exponent is solved for) or directly via ZIPF_BENCH_THETA.
config_zipf_bench(){
    zipf_bench_bytes="${ZIPF_BENCH_BYTES:-$((32 * 1024 * 1024 * 1024))}"
    zipf_bench_page_size="${ZIPF_BENCH_PAGE_SIZE:-4096}"
    zipf_bench_duration="${ZIPF_BENCH_DURATION:-60}"         # seconds
    zipf_bench_hot_frac="${ZIPF_BENCH_HOT_FRAC:-0.2}"
    zipf_bench_hot_access="${ZIPF_BENCH_HOT_ACCESS:-0.8}"
    zipf_bench_theta="${ZIPF_BENCH_THETA:-}"                 # set to override hot-frac/hot-access
    zipf_bench_threads="${ZIPF_BENCH_THREADS:-8}"
    zipf_bench_seed="${ZIPF_BENCH_SEED:-1}"
    zipf_bench_shuffle="${ZIPF_BENCH_SHUFFLE:-1}"            # 0 = hot pages contiguous at buffer start
    zipf_bench_prefault="${ZIPF_BENCH_PREFAULT:-1}"
    zipf_bench_readonly="${ZIPF_BENCH_READONLY:-0}"
    # Workers are pinned one per physical core (within the numactl cpunodebind
    # set); the perf monitor thread takes the next free core.
    zipf_bench_pin="${ZIPF_BENCH_PIN:-1}"
    zipf_bench_thp="${ZIPF_BENCH_THP:-0}"                   # 1 = back buffer with 2 MiB THP (madvise)
    # PEBS L3-miss sampling (MEM_LOAD_RETIRED.L3_MISS), period mode. Outputs
    # land next to the stdout file as <base>_perf_{samples.bin,lost.csv,meta.json,perm.bin};
    # plot with scripts/vis/plot_zipf_bench.py <base>_perf. Don't combine with
    # `-i pebs` (both would program PEBS).
    zipf_bench_perf="${ZIPF_BENCH_PERF:-1}"
    zipf_bench_perf_period="${ZIPF_BENCH_PERF_PERIOD:-1007}"
    zipf_bench_perf_ring_pages="${ZIPF_BENCH_PERF_RING_PAGES:-512}"   # per core, power of 2
    zipf_bench_perf_drop_all="${ZIPF_BENCH_PERF_DROP_ALL:-0}"   # 1 = BPF filter drops every sample in-kernel (needs patched kernel)

    zipf_bench_args="--bytes ${zipf_bench_bytes} --page-size ${zipf_bench_page_size} --duration-s ${zipf_bench_duration} --hot-frac ${zipf_bench_hot_frac} --hot-access ${zipf_bench_hot_access} --threads ${zipf_bench_threads} --seed ${zipf_bench_seed}"
    [[ -n "${zipf_bench_theta}" ]] && zipf_bench_args+=" --theta ${zipf_bench_theta}"
    [[ "${zipf_bench_shuffle}" == "0" ]] && zipf_bench_args+=" --no-shuffle"
    [[ "${zipf_bench_prefault}" == "0" ]] && zipf_bench_args+=" --no-prefault"
    [[ "${zipf_bench_readonly}" == "1" ]] && zipf_bench_args+=" --read-only"
    [[ "${zipf_bench_pin}" == "0" ]] && zipf_bench_args+=" --no-pin"
    [[ "${zipf_bench_thp}" == "1" ]] && zipf_bench_args+=" --thp"
    [[ -n "${ZIPF_BENCH_CPUS:-}" ]] && zipf_bench_args+=" --cpus ${ZIPF_BENCH_CPUS}"   # explicit worker CPUs, e.g. keep off ARMS cores
    # Hot-set change: swap the shuffle once fast-tier occupancy holds steady for this many s.
    [[ -n "${ZIPF_BENCH_RESHUFFLE_ON_STEADY:-}" ]] && zipf_bench_args+=" --reshuffle-on-steady ${ZIPF_BENCH_RESHUFFLE_ON_STEADY}"
    [[ -n "${ZIPF_BENCH_POST_RECOVER_S:-}" ]] && zipf_bench_args+=" --post-recover-s ${ZIPF_BENCH_POST_RECOVER_S}"
    [[ -n "${ZIPF_BENCH_PLACEMENT_INTERVAL_S:-}" ]] && zipf_bench_args+=" --placement-interval-s ${ZIPF_BENCH_PLACEMENT_INTERVAL_S}"
    return 0
}

build_zipf_bench(){
    (cd "$CUR_PATH/microbench/zipf_bench" && make -j$(nproc))
}

run_zipf_bench(){
    local workload=$1
    local bin="$CUR_PATH/microbench/zipf_bench/zipf_bench"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: zipf_bench binary not found at $bin"
        return 1
    fi

    generate_workload_filenames "$workload"
    local args="$zipf_bench_args"
    [[ "${ZIPF_BENCH_PLACEMENT_DUMP:-0}" == "1" ]] && args+=" --placement-dump ${STDOUT%_stdout.txt}_placement.bin"
    if [[ "${zipf_bench_perf}" == "1" ]]; then
        args+=" --perf-out ${STDOUT%_stdout.txt}_perf --perf-period ${zipf_bench_perf_period} --perf-ring-pages ${zipf_bench_perf_ring_pages}"
        [[ "${zipf_bench_perf_drop_all}" == "1" ]] && args+=" --perf-drop-all"
    fi
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$args"
    run_workload_standard
}

run_strace_zipf_bench(){
    return
}

clean_zipf_bench(){
    return
}
