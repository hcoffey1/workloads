#!/bin/bash

config_silo(){
    benchmark=tpcc
    sf=200
    ops=2000000
    num_threads=8
}

build_silo(){
    (cd $CUR_PATH/MERCI/4_performance_evaluation && MODE=perf make -j dbtest)
}

run_silo(){
    local workload="silo"
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_silo_${WORKLOAD}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of dbtest after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest" --verbose --bench "$benchmark" --scale-factor "$sf" --ops-per-worker "$ops" --num-threads "$num_threads"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed dbtest
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

run_strace_silo(){
    strace -e mmap,munmap -o silo_silo_strace.log $CUR_PATH/silo/silo/out-perf.masstree/benchmarks/dbtest --verbose --bench $benchmark --scale-factor $sf --ops-per-worker $ops --num-threads $num_threads
}

clean_silo(){
    return
}
