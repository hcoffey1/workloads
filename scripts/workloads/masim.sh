#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_masim(){
    return
}

build_masim(){
    (cd $CUR_PATH/masim && make -j$(nproc))
}

run_masim(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of masim after exec)
echo \$\$ > "$PIDFILE"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/masim/$workload" "$CUR_PATH/masim/configs/hc.cfg" -c 2
EOF
    chmod +x "$WRAPPER"

    # run with taskset (masim doesn't need sudo or NUMA binding); time measures the wrapper -> execed masim
    /usr/bin/time -v -o "$TIMEFILE" \
        taskset 0xFF \
        "$WRAPPER" \
        1> "$STDOUT" 2> "$STDERR" &

    # wait until wrapper has written pidfile (tiny loop is fine)
    while [ ! -s "$PIDFILE" ]; do sleep 0.01; done
    workload_pid=$(cat "$PIDFILE")
    echo "workload_pid=$workload_pid"

    # optional: cleanup wrapper if you don't need it
    rm -f "$WRAPPER"
}

run_strace_masim(){
    return
}

clean_masim(){
    return
}
