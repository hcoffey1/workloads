#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

#Config 1
    #phase_regions="${PHASE_REGIONS:-32}"
    #phase_region_mb="${PHASE_REGION_MB:-2}"
    #phase_stride="${PHASE_STRIDE:-64}"
    #phase_iters="${PHASE_ITERS:-200}"
    #phase_cycles="${PHASE_CYCLES:-2}"
    ## Zipfian distribution parameters (optional)
    ## To disable zipfian: set PHASE_ZIPF_REGION_MB=0 or unset these variables
    #phase_zipf_region_mb="${PHASE_ZIPF_REGION_MB:-64}"        # 4GB zipfian region (set to 0 to disable)
    #phase_zipf_item_size="${PHASE_ZIPF_ITEM_SIZE:-4096}"        # item size in bytes (default 4KB)
    #phase_zipf_theta="${PHASE_ZIPF_THETA:-0.75}"                # 0.75 for ~1GB hot in 4GB total
    #phase_zipf_rate="${PHASE_ZIPF_RATE:-0}"                     # 0 = unlimited
    #phase_zipf_workload_size="${PHASE_ZIPF_WORKLOAD_SIZE:-3000000000}"   # total accesses (0 = unlimited, runs until sequential done)
    ## Threading parameters
    #phase_threads="${PHASE_THREADS:-8}"                         # number of threads for phase access
    #zipf_threads="${ZIPF_THREADS:-8}"                           # number of threads for zipfian access

config_micro_phase(){
    phase_regions="${PHASE_REGIONS:-4}"
    phase_region_mb="${PHASE_REGION_MB:-2048}"
    phase_stride="${PHASE_STRIDE:-64}"
    phase_iters="${PHASE_ITERS:-5}"
    phase_cycles="${PHASE_CYCLES:-2}"
    # Zipfian distribution parameters (optional)
    # To disable zipfian: set PHASE_ZIPF_REGION_MB=0 or unset these variables
    phase_zipf_region_mb="${PHASE_ZIPF_REGION_MB:-4096}"        # 4GB zipfian region (set to 0 to disable)
    phase_zipf_item_size="${PHASE_ZIPF_ITEM_SIZE:-4096}"        # item size in bytes (default 4KB)
    phase_zipf_theta="${PHASE_ZIPF_THETA:-0.75}"                # 0.75 for ~1GB hot in 4GB total
    phase_zipf_rate="${PHASE_ZIPF_RATE:-0}"                     # 0 = unlimited
    phase_zipf_workload_size="${PHASE_ZIPF_WORKLOAD_SIZE:-3000000000}"   # total accesses (0 = unlimited, runs until sequential done)
    # Threading parameters
    phase_threads="${PHASE_THREADS:-8}"                         # number of threads for phase access
    zipf_threads="${ZIPF_THREADS:-8}"                           # number of threads for zipfian access
}

build_micro_phase(){
    (cd "$CUR_PATH/microbench/micro_phase" && g++ -O0 -std=c++17 -pthread -Wall -Wextra phase_toggle.cpp -o phase_toggle)
}

run_micro_phase(){
    local workload=$1
    local bin="$CUR_PATH/microbench/micro_phase/phase_toggle"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: micro_phase binary not found at $bin"
        return 1
    fi

    generate_workload_filenames "$workload"
    local args="${phase_regions} ${phase_region_mb} ${phase_stride} ${phase_iters} ${phase_cycles}"
    # Add zipfian arguments
    args="${args} ${phase_zipf_region_mb} ${phase_zipf_item_size} ${phase_zipf_theta} ${phase_zipf_rate} ${phase_zipf_workload_size}"
    # Add threading arguments
    args="${args} ${phase_threads} ${zipf_threads}"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$args"
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_micro_phase(){
    return
}

clean_micro_phase(){
    stop_bwmon
    return
}
