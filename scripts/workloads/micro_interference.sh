#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# =============================================================================
# micro_interference Workload Script
# =============================================================================

config_micro_interference() {
    # Global settings
    INTERFERENCE_DURATION="${INTERFERENCE_DURATION:-60}"           # Total benchmark duration (seconds)
    INTERFERENCE_SAMPLE_PERIOD="${INTERFERENCE_SAMPLE_PERIOD:-1000}" # Sampling period (ms)

    # Sequential pattern settings (8 x 2GB = 16GB)
    SEQ_REGIONS="${SEQ_REGIONS:-64}"                   # Number of sequential regions
    SEQ_REGION_MB="${SEQ_REGION_MB:-64}"            # Size of each region (MB) = 2GB
    SEQ_STRIDE="${SEQ_STRIDE:-64}"                  # Access stride (bytes)
    SEQ_DELAY="${SEQ_DELAY:-0}"                       # Delay before starting (seconds)
    SEQ_RUNTIME="${SEQ_RUNTIME:-0}"                   # Runtime (0 = global duration)
    SEQ_PHASE_DURATION="${SEQ_PHASE_DURATION:-1}"             # Seconds per sequential region
    SEQ_THREADS="${SEQ_THREADS:-8}"                   # Number of threads

    # Zipfian pattern settings (16GB)
    ZIPF_REGION_MB="${ZIPF_REGION_MB:-4096}"         # Zipfian region size = 16GB
    ZIPF_ITEM_SIZE="${ZIPF_ITEM_SIZE:-4096}"          # Item size (bytes)
    ZIPF_THETA="${ZIPF_THETA:-0.8}"                  # Skew parameter
    ZIPF_DELAY="${ZIPF_DELAY:-0}"                     # Delay before starting (seconds)
    ZIPF_RUNTIME="${ZIPF_RUNTIME:-0}"                 # Runtime (0 = global duration)
    ZIPF_THREADS="${ZIPF_THREADS:-8}"                 # Number of threads
}

build_micro_interference() {
    local src="$CUR_PATH/microbench/micro_interference/micro_interference.cpp"
    local bin="$CUR_PATH/microbench/micro_interference/micro_interference"

    echo "Building micro_interference..."
    (cd "$CUR_PATH/microbench/micro_interference" && \
     g++ -O3 -std=c++17 -pthread -Wall -Wextra "$src" -o "$bin")

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: Build failed for micro_interference"
        return 1
    fi
    echo "Build successful: $bin"
}

run_micro_interference() {
    local workload=$1
    local bin="$CUR_PATH/microbench/micro_interference/micro_interference"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: micro_interference binary not found at $bin"
        return 1
    fi

    local extra_envs=""
    if [[ -n "${REGENT_REGIONS:-}" ]]; then
        echo "Using provided REGENT_REGIONS: $REGENT_REGIONS"
        extra_envs="export REGENT_REGIONS=\"$REGENT_REGIONS\""
    elif [[ -n "${SEQ_VA_RANGE:-}" ]]; then
        local hybrid_pol="${HYBRID_POLICY:-lru_ptscan}"
        local regent_regions="${hybrid_pol}:${SEQ_VA_RANGE}:${SEQ_ARMS_SIZE:-128M}"
        echo "Using Hardcoded Sequential VA Range: $SEQ_VA_RANGE"
        echo "Set REGENT_REGIONS=$regent_regions"
        extra_envs="export REGENT_REGIONS=\"$regent_regions\""
    fi

    if [[ -n "${REGENT_ANNOTATION_FILE:-}" ]]; then
        if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
        # Append iteration to filename to avoid overwriting/mixing
        local anno_file="${REGENT_ANNOTATION_FILE}"
        if [[ -n "${CURRENT_ITERATION:-}" ]]; then
             if [[ "$anno_file" == *.* ]]; then
                 local ext="${anno_file##*.}"
                 local base="${anno_file%.*}"
                 anno_file="${base}_iter${CURRENT_ITERATION}.${ext}"
             else
                 anno_file="${anno_file}_iter${CURRENT_ITERATION}"
             fi
        fi
        extra_envs+="export REGENT_ANNOTATION_FILE=\"$anno_file\""
    fi

    if [[ -n "${REGENT_NUM_REGIONS:-}" ]]; then
        if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
        extra_envs+="export REGENT_NUM_REGIONS=\"$REGENT_NUM_REGIONS\""
    fi

    # Always use huge pages
    if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
    extra_envs+="export USE_HUGETLB=1"

    generate_workload_filenames "$workload"

    local args=""
    args="$args --duration $INTERFERENCE_DURATION"
    args="$args --sample-period $INTERFERENCE_SAMPLE_PERIOD"

    # Sequential args
    args="$args --seq-regions $SEQ_REGIONS"
    args="$args --seq-region-mb $SEQ_REGION_MB"
    args="$args --seq-stride $SEQ_STRIDE"
    args="$args --seq-delay $SEQ_DELAY"
    args="$args --seq-runtime $SEQ_RUNTIME"
    args="$args --seq-phase-duration $SEQ_PHASE_DURATION"
    args="$args --seq-threads $SEQ_THREADS"

    # Zipfian args
    args="$args --zipf-region-mb $ZIPF_REGION_MB"
    args="$args --zipf-item-size $ZIPF_ITEM_SIZE"
    args="$args --zipf-theta $ZIPF_THETA"
    args="$args --zipf-delay $ZIPF_DELAY"
    args="$args --zipf-runtime $ZIPF_RUNTIME"
    args="$args --zipf-threads $ZIPF_THREADS"

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$args" "$extra_envs"
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
    start_mpstat
    start_perf_monitor
    start_cpufreq
}

run_strace_micro_interference() {
    return
}

clean_micro_interference() {
    stop_bwmon || true
    stop_mpstat || true
    stop_perf_monitor || true
    stop_cpufreq || true
    return
}
