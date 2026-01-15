#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_masim(){
    local config_override="$1"

    #masim_config="${config_override:-$CUR_PATH/masim/configs/huge_stairs_30secs.cfg}"
    masim_config="${config_override:-$CUR_PATH/masim/configs/zipf_seq_parallel_20s.cfg}"
}

build_masim(){
    (cd $CUR_PATH/masim && make -j$(nproc))
}

run_masim(){
    local workload=$1

    local masim_bin="$CUR_PATH/masim/$workload"

    if [[ ! -x "$masim_bin" ]]; then
        echo "ERROR: masim binary not found at $masim_bin"
        return 1
    fi

    if [[ ! -f "$masim_config" ]]; then
        echo "ERROR: masim config not found at $masim_config"
        return 1
    fi

    generate_workload_filenames "$workload"

    local masim_args="\"$masim_config\""
    if [[ -n "${MASIM_EXTRA_ARGS:-}" ]]; then
        masim_args+=" ${MASIM_EXTRA_ARGS}"
    fi

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$masim_bin" "$masim_args"

    run_workload_standard "--cpunodebind=0 -p 0"
}

run_strace_masim(){
    return
}

clean_masim(){
    return
}
