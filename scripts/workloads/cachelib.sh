#!/bin/bash

config_cachelib(){
    #TODO: Update test config, this one is too small.
    cachelib_json=$CUR_PATH/CacheLib/cachelib/cachebench/test_configs/simple_test.json
    return
}

build_cachelib(){
    pushd $CUR_PATH/CacheLib

    # CacheLib needs fastfloat installed to run.
    #git clone https://github.com/fastfloat/fast_float.git
    #pushd fast_float
    #cmake -B build -DFASTFLOAT_TEST=OFF
    #sudo cmake --build build --target install
    #popd

    ./contrib/build.sh -j -T

    popd
}

run_cachelib(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_cachelib_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of cachebench after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/CacheLib/opt/cachelib/bin/cachebench" \\
    --json_test_config "$cachelib_json"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed cachebench
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

run_strace_cachelib(){
    return
}

clean_cachelib(){
    rm -f logs.txt stats.txt times.txt
    return
}
