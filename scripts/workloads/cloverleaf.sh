#!/bin/bash

config_cloverleaf(){
    WORK_DIR=$CUR_PATH/CloverLeaf/CloverLeaf_OpenMP/
    num_threads=16
    cp $WORK_DIR/InputDecks/clover_bm16_short.in ./clover.in
}

build_cloverleaf(){
    pushd $WORK_DIR

    make COMPILER=GNU -j $(nproc)

    popd
}

run_cloverleaf(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_cloverleaf_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of clover_leaf after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
export OMP_NUM_THREADS="$num_threads"

# replace shell with the real binary so PID stays the same
exec "$WORK_DIR/clover_leaf"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed clover_leaf
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

    # BW Monitoring
    sudo $CUR_PATH/scripts/cipp-workspace/tools/bwmon 500 \
        > ${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_bwmon.txt &
    bwmon_pid=$!
}

run_strace_cloverleaf(){
    return
}

clean_cloverleaf(){
    sudo kill "$bwmon_pid"
    rm -f clover.in times.txt logs.txt stats.txt clover.in.tmp clover.out
    return
}
