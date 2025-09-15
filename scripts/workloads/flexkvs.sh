#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_flexkvs(){
    num_threads=8
    kv_size=$((32*1024*1024*1024))
    warmup_time=20
    run_time=100
}

build_flexkvs(){
    (cd $CUR_PATH/flexkvs && make -j$(nproc))
}

run_flexkvs(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/flexkvs/kvsbench" "-t \"$num_threads\" -T \"$run_time\" -w \"$warmup_time\" -h 0.25 127.0.0.1:1211 -S \"$kv_size\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"
}

run_strace_flexkvs(){
    strace -e mmap,munmap -o flexkvs_flexkvs_strace.log $CUR_PATH/flexkvs/kvsbench -t $num_threads -T $run_time -w $warmup_time -h 0.25 127.0.0.1:1211 -S $kv_size
}

clean_flexkvs(){
    return
}
