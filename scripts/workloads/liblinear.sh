#!/bin/bash

#TODO: Where to get dataset?
config_liblinear(){
    num_threads=16
    dataset=$CUR_PATH/liblinear-2.47/kdd12
}

build_liblinear(){
    (cd $CUR_PATH/liblinear-2.47 && make -j$(nproc))
}

run_liblinear(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_liblinear_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of train after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/liblinear-2.47/train" -s 6 -m "$num_threads" "$dataset"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed train
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

    # BW monitoring
    sudo $CUR_PATH/scripts/cipp-workspace/tools/bwmon 500 \
        > ${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_bwmon.txt &
    bwmon_pid=$!
}

run_strace_liblinear(){
    strace -e mmap,munmap -o liblinear_liblinear_strace.log $CUR_PATH/liblinear-2.47/train -s 6 -m $num_threads $dataset
}

clean_liblinear(){
    sudo kill "$bwmon_pid"
    return
}
