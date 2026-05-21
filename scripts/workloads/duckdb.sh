#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_duckdb(){
    local _config_file="$1"
    local _workload="$2"

    num_threads=8

    cache_db=""
    cache_suite=""
    cache_sf=""

    case "$_workload" in
        tpcds_sf100)
            benchmark_pattern="benchmark/large/tpcds-sf100/.*"
            cache_db="tpcds_sf100.duckdb"
            cache_suite="tpcds"
            cache_sf=100
            ;;
        tpcds_sf100_q10)
            benchmark_pattern="benchmark/large/tpcds-sf100/q(0[1-9]|10)\.benchmark"
            cache_db="tpcds_sf100.duckdb"
            cache_suite="tpcds"
            cache_sf=100
            ;;
        tpch_sf100)
            benchmark_pattern="benchmark/large/tpch-sf100/.*"
            cache_db="tpch_sf100.duckdb"
            cache_suite="tpch"
            cache_sf=100
            ;;
        ingestion)
            benchmark_pattern="benchmark/large/ingestion/.*"
            ;;
        other_large)
            benchmark_pattern="benchmark/large/other/.*"
            ;;
        *)
            echo "ERROR: unknown duckdb workload '$_workload'" >&2
            echo "Valid workloads: tpcds_sf100, tpcds_sf100_q10, tpch_sf100, ingestion, other_large" >&2
            exit 1
            ;;
    esac
}

build_duckdb(){
    local _workload="$1"

    (cd "$CUR_PATH/duckdb" && BUILD_BENCHMARK=1 BUILD_EXTENSIONS='tpch;tpcds' make -j$(nproc))

    if [[ -n "$cache_db" ]]; then
        local cache_path="$CUR_PATH/duckdb/duckdb_benchmark_data/$cache_db"
        if [[ ! -f "$cache_path" ]]; then
            echo "[WARN] Cached database $cache_path is missing."
            echo "[WARN] Building via duckdb/scripts/build_benchmark_cache.sh; this can take a long time for sf=100."
            (cd "$CUR_PATH/duckdb" && scripts/build_benchmark_cache.sh "$cache_suite" "$cache_sf")
        fi
    fi
}

run_duckdb(){
    local workload=$1

    generate_workload_filenames "$workload"

    local timings_file="${OUTPUT_DIR}/${SUITE}_${workload}_${hemem_policy}_${DRAMSIZE}"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        timings_file+="_iter${CURRENT_ITERATION}"
    fi
    timings_file+="_timings.txt"

    local binary_path="$CUR_PATH/duckdb/build/release/benchmark/benchmark_runner"
    local binary_args="--root-dir \"$CUR_PATH/duckdb\" --threads=$num_threads --disable-timeout --no-warmup --out=\"$timings_file\" \"$benchmark_pattern\""

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "$binary_args"

    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

clean_duckdb(){
    stop_bwmon
    return
}
