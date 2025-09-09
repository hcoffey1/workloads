#!/bin/bash
# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_xsbench(){
    num_threads=16
    particles=20000000 # Should take about 64G
    gridpoints=130000
}

build_xsbench(){
    (cd $CUR_PATH/XSBench/openmp-threading && make -j$(nproc))
}

run_xsbench(){
    local workload="xsbench"
    
    # Use utility functions to set up and run workload
    generate_workload_filenames "$workload"
    
    # Set OpenMP threads in the wrapper creation
    local binary_path="$CUR_PATH/XSBench/openmp-threading/XSBench"
    local binary_args="-t $num_threads -p $particles -g $gridpoints"
    
    # Create wrapper with OMP_NUM_THREADS environment variable
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "$binary_args" "export OMP_NUM_THREADS=\"$num_threads\""
    
    # Run with standard execution
    run_workload_standard "--cpunodebind=0 --membind=0"
}

run_strace_xsbench(){
    OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o xsbench_xsbench_strace.log $CUR_PATH/XSBench/openmp-threading/XSBench -t $num_threads -p $particles -g $gridpoints
}

clean_xsbench(){
    return
}
