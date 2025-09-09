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
    (cd $CUR_PATH/MERCI/4_performance_evaluation && MODE=perf make -j dbtest)
}

run_silo(){
    local workload="silo"
    
    # Generate filenames using utility function
    local filenames
    filenames=$(generate_workload_filenames "$SUITE" "$WORKLOAD" "$hemem_policy" "$DRAMSIZE" "$OUTPUT_DIR")
    eval "$filenames"
    
    WRAPPER="${OUTPUT_DIR}/run_silo_${WORKLOAD}.sh"

    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest" "--verbose --bench \"$benchmark\" --scale-factor \"$sf\" --ops-per-worker \"$ops\" --num-threads \"$num_threads\""

    # Use standard workload execution
    run_workload_standard "$WRAPPER"
}

run_strace_silo(){
    strace -e mmap,munmap -o silo_silo_strace.log $CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest --verbose --bench $benchmark --scale-factor $sf --ops-per-worker $ops --num-threads $num_threads
}

clean_silo(){
    return
}
