#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_silo(){
    benchmark=tpcc
    sf=200
    ops=2000000
    num_threads=8
}

build_silo(){
    (cd $CUR_PATH/silo/silo && MODE=perf make -j$(nproc) dbtest)
}

run_silo(){
    local workload=$1

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest" "--verbose --bench \"$benchmark\" --scale-factor \"$sf\" --ops-per-worker \"$ops\" --num-threads \"$num_threads\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_silo(){
    strace -e mmap,munmap -o silo_silo_strace.log $CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest --verbose --bench $benchmark --scale-factor $sf --ops-per-worker $ops --num-threads $num_threads
}

clean_silo(){
    stop_bwmon
    return
}
