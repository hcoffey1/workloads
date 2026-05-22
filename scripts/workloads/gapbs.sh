#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_gapbs(){
    num_threads=8
    num_rep=20
    graph_size=26
    #graph_size=27
    graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitter.sg
    graph_path_u=$CUR_PATH/gapbs/benchmark/graphs/twitterU.sg
    w_graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitter.wsg
}

build_gapbs(){
    (cd $CUR_PATH/gapbs && make -j$(nproc) && make bench-graphs -j 1)
}

# Resolve a workload name into "<kernel>|<input-args>".
# Plain "bc" → synthetic kron via `-g $graph_size`.
# "bc_twitter" → twitter graph; file format depends on kernel:
#   sssp needs .wsg (weighted), tc needs twitterU.sg (symmetrized), rest use twitter.sg.
_gapbs_resolve(){
    local workload=$1
    local kernel input
    case "$workload" in
        *_twitter)
            kernel=${workload%_twitter}
            case "$kernel" in
                sssp) input="-f $w_graph_path" ;;
                tc)   input="-f $graph_path_u" ;;
                *)    input="-f $graph_path"   ;;
            esac
            ;;
        *)
            kernel=$workload
            input="-g $graph_size"
            ;;
    esac
    echo "$kernel|$input"
}

run_gapbs(){
    local workload=$1
    local reps="$num_rep"

    local resolved kernel input
    resolved=$(_gapbs_resolve "$workload")
    kernel=${resolved%%|*}
    input=${resolved#*|}

    if [[ "$kernel" == "tc" ]]; then
        reps=4
    fi

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/gapbs/$kernel" "-n \"$reps\" $input" "export OMP_NUM_THREADS=\"$num_threads\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_gapbs(){
    local workload=$1
    local resolved kernel input
    resolved=$(_gapbs_resolve "$workload")
    kernel=${resolved%%|*}
    input=${resolved#*|}

    OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o gapbs_${workload}_strace.log $CUR_PATH/gapbs/$kernel -n $num_rep $input &

    workload_pid=$!
}

clean_gapbs(){
    stop_bwmon
    return
}
