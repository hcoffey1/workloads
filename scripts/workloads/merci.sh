#!/bin/bash

config_merci(){
    num_threads=8
    num_reps=5
}

build_merci(){
    (cd $CUR_PATH/MERCI/4_performance_evaluation && make -j$(nproc))
}

run_merci(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_merci_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of eval_baseline after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
export HOME="$CUR_PATH"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline" --dataset amazon_All -r "$num_reps" -c "$num_threads"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed eval_baseline
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

run_strace_merci(){
    HOME=$CUR_PATH strace -e mmap,munmap -o merci_merci_strace.log $CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline --dataset amazon_All -r $num_reps -c $num_threads
}

clean_merci(){
    return
}
