#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_merci(){
    num_threads=8
    num_reps=5
}

build_merci(){
    (cd $CUR_PATH/MERCI/4_performance_evaluation && make -j$(nproc))
}

run_merci(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function (with custom HOME environment variable)
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline" "--dataset amazon_All -r \"$num_reps\" -c \"$num_threads\"" "export HOME=\"$CUR_PATH\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"

    start_bwmon
}

run_strace_merci(){
    HOME=$CUR_PATH strace -e mmap,munmap -o merci_merci_strace.log $CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline --dataset amazon_All -r $num_reps -c $num_threads
}

clean_merci(){
    stop_bwmon
    return
}
