#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_graph500(){
    num_threads=8
    size=26
    skip_validation=1
}

build_graph500(){
    pushd $CUR_PATH/graph500 > /dev/null

    cp make-incs/make.inc-gcc make.inc

    #Change makefile gcc version and enable openmp
    sed -i -e 's/^CC = gcc-4.6/CC = gcc/' \
        -e 's/^# \(BUILD_OPENMP = Yes\)/\1/' \
        -e 's/^# \(CFLAGS_OPENMP = -fopenmp\)/\1/' make.inc

    (make -j$(nproc))

    popd
}

run_graph500(){
    local workload=$1
    
    # Use utility functions to set up filenames
    generate_workload_filenames "$workload"

    # Use utility function to create and run workload
    local binary_path="$CUR_PATH/graph500/omp-csr/omp-csr"
    local binary_args="-s $size -V"
    
    # Create wrapper with specific environment variables
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "$binary_args" \
        "export SKIP_VALIDATION=\"$skip_validation\"
export OMP_NUM_THREADS=\"$num_threads\""
    
    # Run with standard execution
    run_workload_standard "--cpunodebind=0 --membind=0"
}

run_strace_graph500(){
    SKIP_VALIDATION=$skip_validation OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o graph500_xsbench_strace.log $CUR_PATH/graph500/omp-csr/omp-csr -s $size -V
}

clean_graph500(){
    return
}
