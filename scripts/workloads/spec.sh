#!/bin/bash

config_spec(){
    SPEC_PATH=/mydata/spec/cpu2017/
    WORK_SIZE="ref"
}

build_spec(){
    (cd $SPEC_PATH && source shrc && runcpu --config=try1 --action=build intrate && runcpu --config=try1 --action=build fprate)
}

run_spec(){

    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_spec_${workload}.sh"

    # TODO: Support multiple $workload in here.
    # Translate $workload to offical spec name for file pathing.
    # cactus -> 507.cactuBSSN_r
        # exec $SPEC_PATH/benchspec/CPU/507.cactuBSSN_r/build/build_base_hayden-mytest-m64.0000/cactusBSSN_r $SPEC_PATH/benchspec/CPU/507.cactuBSSN_r/data/refrate/input/spec_ref.par
    # mcf -> 505.mcf_r
        # exec $SPEC_PATH/benchspec/CPU/505.mcf_r/build/build_base_hayden-mytest-m64.0000/mcf_r $SPEC_PATH/benchspec/CPU/505.mcf_r/data/refrate/input/inp.in
    # deepsjeng -> 531.deepsjeng_r
        # exec $SPEC_PATH/benchspec/CPU/531.deepsjeng_r/build/build_base_hayden-mytest-m64.0000/deepsjeng_r $SPEC_PATH/benchspec/CPU/531.deepsjeng_r/data/refrate/input/ref.txt

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of gapbs binary after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

cd $SPEC_PATH/benchspec/CPU/505.mcf_r/run/run_base_train_hayden-mytest-m64.0000

# replace shell with the real binary so PID stays the same
exec ./mcf_r_base.hayden-mytest-m64 inp.in
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
    rm -f "$PIDFILE"
}

run_strace_spec(){
    return
}

clean_spec(){
    return
}
