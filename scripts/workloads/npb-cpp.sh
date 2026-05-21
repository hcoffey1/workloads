#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"
set -x

config_npb-cpp(){
    NPB_CLASS=D
    num_threads=8
}

build_npb-cpp(){
    local workload=$1
    # NPB's benchmark subdirs invoke ../sys/setparams to generate npbparams.hpp;
    # with `make -j` the sys/setparams build can race with that invocation, so
    # build setparams sequentially first.
    # `make clean` first: NPB doesn't reliably invalidate stale .o/npbparams.hpp
    # when only CLASS changes, so switching from e.g. C→D otherwise yields the
    # old binary. Cheap to rebuild from scratch.
    (cd $CUR_PATH/NPB-CPP/NPB-OMP && make clean) && \
    (cd $CUR_PATH/NPB-CPP/NPB-OMP/sys && make) && \
    (cd $CUR_PATH/NPB-CPP/NPB-OMP && make -j$(nproc) $workload CLASS=$NPB_CLASS)
}

run_npb-cpp(){
    local workload=$1

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    create_workload_wrapper "$WRAPPER" "$PIDFILE" \
        "$CUR_PATH/NPB-CPP/NPB-OMP/bin/${workload}.${NPB_CLASS}" "" \
        "export OMP_NUM_THREADS=\"$num_threads\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_npb-cpp(){
    local workload=$1
    # STUB
    workload_pid=$!
}

clean_npb-cpp(){
    stop_bwmon
    return
}
