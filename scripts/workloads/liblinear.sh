#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

#TODO: Where to get dataset?
config_liblinear(){
    num_threads=16
    dataset=$CUR_PATH/liblinear-2.47/kdd12
}

build_liblinear(){
    (cd $CUR_PATH/liblinear-2.47 && make -j$(nproc))
}

run_liblinear(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/liblinear-2.47/train" "-s 6 -m \"$num_threads\" \"$dataset\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"

    # BW monitoring
    start_bwmon
}

run_strace_liblinear(){
    strace -e mmap,munmap -o liblinear_liblinear_strace.log $CUR_PATH/liblinear-2.47/train -s 6 -m $num_threads $dataset
}

clean_liblinear(){
    stop_bwmon
    return
}
