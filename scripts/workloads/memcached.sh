
#!/bin/bash
set -x
config_memcached(){
    client_threads=16
    server_threads=4
}

build_memcached(){
    # Build memcached
    pushd $CUR_PATH/memcached > /dev/null

    ./autogen.sh
    ./configure
    (make -j$(nproc))

    popd

    # Build YCSB with memcached bindings
    pushd $CUR_PATH/YCSB > /dev/null

    mvn -pl site.ycsb:memcached-binding -am clean package

    popd

}

run_memcached(){
    local workload=$1

    # Start memcached server (64 GB), bind to NUMA node 0
    numactl --cpunodebind=0 --membind=0 \
        sudo LD_PRELOAD=$HEMEMPOL DRAMSIZE=$DRAMSIZE MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
        $CUR_PATH/memcached/memcached -u $(whoami) -d -p 11211 -m 67108864 -t $server_threads

    sleep 5

    pushd $CUR_PATH/YCSB > /dev/null

    # SETUP: Load data into data base.
    ./bin/ycsb load memcached -s -P $CUR_PATH/YCSB/workloads/workloada \
        -p "memcached.hosts=127.0.0.1" -threads $client_threads

    sleep 5

    # RUN: Record performance
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_memcached_${workload}.sh"

    # create wrapper for YCSB client (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of ycsb after exec)
echo \$\$ > "$PIDFILE"

# change to YCSB directory
cd "$CUR_PATH/YCSB"

# replace shell with the real binary so PID stays the same
exec ./bin/ycsb run memcached -s -P "$CUR_PATH/YCSB/workloads/workloada" \\
    -p "memcached.hosts=127.0.0.1" -threads "$client_threads"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed ycsb
    /usr/bin/time -v -o "$TIMEFILE" \
        numactl --cpunodebind=1 --membind=1 \
        "$WRAPPER" \
        1> "$STDOUT" 2> "$STDERR" &

    # wait until wrapper has written pidfile (tiny loop is fine)
    while [ ! -s "$PIDFILE" ]; do sleep 0.01; done
    workload_pid=$(cat "$PIDFILE")
    echo "workload_pid=$workload_pid"

    # optional: cleanup wrapper if you don't need it
    rm -f "$WRAPPER"

    popd
}

run_strace_memcached(){
    return
}

clean_memcached(){
    echo "Cleaning up."
    sudo killall memcached
    return
}
