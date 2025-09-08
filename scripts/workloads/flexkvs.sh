#!/bin/bash

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
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_flexkvs_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of kvsbench after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/flexkvs/kvsbench" -t "$num_threads" -T "$run_time" -w "$warmup_time" -h 0.25 127.0.0.1:1211 -S "$kv_size"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed kvsbench
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

run_strace_flexkvs(){
    strace -e mmap,munmap -o flexkvs_flexkvs_strace.log $CUR_PATH/flexkvs/kvsbench -t $num_threads -T $run_time -w $warmup_time -h 0.25 127.0.0.1:1211 -S $kv_size
}

clean_flexkvs(){
    return
}
