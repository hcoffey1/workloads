#!/bin/bash

translate_workload(){
    case "$1" in
        "cactus")
            echo "507.cactuBSSN_r"
            ;;
        "mcf")
            echo "505.mcf_r"
            ;;
        "deepsjeng")
            echo "531.deepsjeng_r"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

config_spec(){
    SPEC_PATH=/mydata/spec/cpu2017/
    WORK_SIZE="ref"
}

build_spec(){
    spec_workload=$(translate_workload $1)
    (cd $SPEC_PATH && source shrc && runcpu --config=try1 --action=build $spec_workload)
}

run_spec(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_spec_${workload}.sh"

    # Define workload-specific parameters
    local binary_path input_file_path

    case "$workload" in
        "cactus")
            #spec_dir="507.cactuBSSN_r"
            binary_path="$SPEC_PATH/benchspec/CPU/507.cactuBSSN_r/build/build_base_hayden-mytest-m64.0000/cactusBSSN_r"
            input_file_path="$SPEC_PATH/benchspec/CPU/507.cactuBSSN_r/data/refrate/input/spec_ref.par"
            ;;
        "mcf")
            #spec_dir="505.mcf_r"
            binary_path="$SPEC_PATH/benchspec/CPU/505.mcf_r/build/build_base_hayden-mytest-m64.0000/mcf_r"
            input_file_path="$SPEC_PATH/benchspec/CPU/505.mcf_r/data/refrate/input/inp.in"
            ;;
        "deepsjeng")
            #spec_dir="531.deepsjeng_r"
            binary_path="$SPEC_PATH/benchspec/CPU/531.deepsjeng_r/build/build_base_hayden-mytest-m64.0000/deepsjeng_r"
            input_file_path="$SPEC_PATH/benchspec/CPU/531.deepsjeng_r/data/refrate/input/ref.txt"
            ;;
        *)
            echo "ERROR: Unsupported SPEC workload '$workload'"
            echo "Supported workloads: cactus, mcf, deepsjeng"
            exit 1
            ;;
    esac

    # Validate that the binary exists
    if [[ ! -f "$binary_path" ]]; then
        echo "ERROR: SPEC binary not found: $binary_path"
        echo "Make sure SPEC has been built for workload: $workload"
        exit 1
    fi

    # Validate that the input file exists
    if [[ ! -f "$input_file_path" ]]; then
        echo "ERROR: SPEC input file not found: $input_file_path"
        echo "Make sure SPEC data is available for workload: $workload"
        exit 1
    fi

    echo "Running SPEC workload: $workload"
    echo "Binary: $binary_path"
    echo "Input file: $input_file_path"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of SPEC binary after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"

# replace shell with the real binary so PID stays the same
exec "$binary_path" "$input_file_path"
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed SPEC binary
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
