#!/bin/bash

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
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_xsbench_${WORKLOAD}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of XSBench after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
export OMP_NUM_THREADS="$num_threads"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/XSBench/openmp-threading/XSBench" -t "$num_threads" -p "$particles" -g "$gridpoints"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed XSBench
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

run_strace_xsbench(){
    OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o xsbench_xsbench_strace.log $CUR_PATH/XSBench/openmp-threading/XSBench -t $num_threads -p $particles -g $gridpoints
}

clean_xsbench(){
    return
}
