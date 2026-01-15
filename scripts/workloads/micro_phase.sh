#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_micro_phase(){
    phase_regions="${PHASE_REGIONS:-8}"
    phase_region_mb="${PHASE_REGION_MB:-4096}"
    phase_stride="${PHASE_STRIDE:-4096}"
    phase_iters="${PHASE_ITERS:-50}"
    phase_cycles="${PHASE_CYCLES:-20}"
}

build_micro_phase(){
    (cd "$CUR_PATH/micro_phase" && g++ -O0 -std=c++17 -Wall -Wextra phase_toggle.cpp -o phase_toggle)
}

run_micro_phase(){
    local workload=$1
    local bin="$CUR_PATH/micro_phase/phase_toggle"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: micro_phase binary not found at $bin"
        return 1
    fi

    generate_workload_filenames "$workload"
    local args="${phase_regions} ${phase_region_mb} ${phase_stride} ${phase_iters} ${phase_cycles}"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$args"
    run_workload_standard "--cpunodebind=0 -p 0"
}

run_strace_micro_phase(){
    return
}

clean_micro_phase(){
    return
}
