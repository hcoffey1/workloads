#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_seq_slope_bench(){
    seq_slope_bytes="${SEQ_SLOPE_BYTES:-$((16 * 1024 * 1024 * 1024))}"
    seq_slope_stride="${SEQ_SLOPE_STRIDE:-64}"
    seq_slope_duration="${SEQ_SLOPE_DURATION:-100000}"
    seq_slope_rate="${SEQ_SLOPE_RATE:-100}"
    seq_slope_prefault="${SEQ_SLOPE_PREFAULT:-1}"
    seq_slope_readonly="${SEQ_SLOPE_READONLY:-0}"
    seq_slope_threads="${SEQ_SLOPE_THREADS:-16}"

    seq_slope_args="--bytes ${seq_slope_bytes} --stride ${seq_slope_stride} --duration-ms ${seq_slope_duration} --slope ${seq_slope_rate} --threads ${seq_slope_threads}"
    if [[ "${seq_slope_prefault}" == "0" ]]; then
        seq_slope_args+=" --no-prefault"
    fi
    if [[ "${seq_slope_readonly}" == "1" ]]; then
        seq_slope_args+=" --read-only"
    fi
}

build_seq_slope_bench(){
    (cd "$CUR_PATH/seq_slope_bench" && make -j$(nproc))
}

run_seq_slope_bench(){
    local workload=$1
    local bin="$CUR_PATH/seq_slope_bench/seq_slope_bench"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: seq_slope_bench binary not found at $bin"
        return 1
    fi

    generate_workload_filenames "$workload"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$seq_slope_args"
    run_workload_standard "--cpunodebind=0 -p 0"
}

run_strace_seq_slope_bench(){
    return
}

clean_seq_slope_bench(){
    return
}
