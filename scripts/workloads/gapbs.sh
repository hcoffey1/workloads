#!/bin/bash

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
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_gapbs_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of gapbs binary after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
export OMP_NUM_THREADS="$num_threads"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/gapbs/$workload" -n "$num_rep" -g "$graph_size"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed gapbs binary
    sudo numactl --cpunodebind=0 --membind=0 \
        /usr/bin/time -v -o "$TIMEFILE" \
        "$WRAPPER" \
        1> "$STDOUT" 2> "$STDERR" &

    # wait until wrapper has written pidfile (tiny loop is fine)
    while [ ! -s "$PIDFILE" ]; do sleep 0.01; done
    workload_pid=$(cat "$PIDFILE")
    echo "workload_pid=$workload_pid"

    # optional: cleanup wrapper if you don't need it
    rm -f "$WRAPPER"
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
