#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_gapbs(){
    num_threads=8
    num_rep=5
    num_iter=5
    graph_size=27
    graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitterU.sg
    w_graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitter.wsg
}

build_gapbs(){
    (cd $CUR_PATH/gapbs && make -j$(nproc) && make bench-graphs -j$(nproc))
}

run_gapbs(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/gapbs/$workload" "-n \"$num_rep\" -g \"$graph_size\"" "export OMP_NUM_THREADS=\"$num_threads\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"
}

run_strace_gapbs(){
    local workload=$1

    if [ $workload == "cc" ] || [ $workload == "cc_sv" ] || [ $workload == "bfs" ] || [ $workload == "tc" ]; then
        OMP_NUM_THREADS=$num_threads taskset 0xFF \
            strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -g $graph_size &
            #strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -f $graph_path &
    elif [ $workload == "sssp" ]; then
        OMP_NUM_THREADS=$num_threads taskset 0xFF \
            strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -g $graph_size &
            #strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -f $w_graph_path &
    else
        OMP_NUM_THREADS=$num_threads taskset 0xFF \
            strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -g $graph_size &
            #strace -e mmap,munmap -o gapbs_$1_strace.log $CUR_PATH/gapbs/$1 -n $num_rep -f $graph_path &
    fi

    workload_pid=$!
}

clean_gapbs(){
    return
}
