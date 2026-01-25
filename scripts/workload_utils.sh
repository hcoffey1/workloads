#!/bin/bash

# ==============================================================================
# WORKLOAD UTILITY FUNCTIONS
# ==============================================================================
# Helper functions for workload scripts to reduce redundancy and standardize
# common operations like filename generation and wrapper script creation.

# Generate output filename with iteration number
generate_workload_filenames() {
    local workload_name="$1"
    local suite_name="${SUITE:-$workload_name}"

    # Generate base filename with iteration
    local base_filename="${OUTPUT_DIR}/${suite_name}_${workload_name}_${hemem_policy}_${DRAMSIZE}"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        base_filename+="_iter${CURRENT_ITERATION}"
    fi

    # Export standard filename variables for use by workload scripts
    export TIMEFILE="${base_filename}_time.txt"
    export STDOUT="${base_filename}_stdout.txt"
    export STDERR="${base_filename}_stderr.txt"
    export BWMON="${base_filename}_bwmon.txt"
    export PIDFILE="${base_filename}.pid"
    export WRAPPER="${OUTPUT_DIR}/run_${suite_name}_${workload_name}_iter${CURRENT_ITERATION:-0}.sh"
}

# Create a standard wrapper script for workloads
create_workload_wrapper() {
    local wrapper_path="$1"
    local pidfile_path="$2"
    local binary_path="$3"
    local binary_args="${4:-}"
    local extra_env_vars="${5:-}"  # Optional extra environment variables

    # Validate required parameters
    if [[ -z "$wrapper_path" ]]; then
        echo "ERROR: create_workload_wrapper requires wrapper_path as first argument"
        return 1
    fi

    if [[ -z "$pidfile_path" ]]; then
        echo "ERROR: create_workload_wrapper requires pidfile_path as second argument"
        return 1
    fi

    if [[ -z "$binary_path" ]]; then
        echo "ERROR: create_workload_wrapper requires binary_path as third argument"
        return 1
    fi

    echo $pidfile_path
    # Convert pidfile_path to absolute path if it's relative
    #if [[ ! "$pidfile_path" = /* ]]; then
    #    pidfile_path="$(pwd)/$pidfile_path"
    #fi

#export LD_PRELOAD="/users/hjcoffey/arms/Hoard/src/libhoard.so:$HEMEMPOL"
#export LD_PRELOAD="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so:$HEMEMPOL"
    # Create wrapper script
    cat > "$wrapper_path" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of the binary after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$SYS_ALLOC:$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
EOF

    # Add any extra environment variables if provided
    if [[ -n "$extra_env_vars" ]]; then
        echo "$extra_env_vars" >> "$wrapper_path"
    fi

    # Add the exec command
    echo "" >> "$wrapper_path"
    echo "# replace shell with the real binary so PID stays the same" >> "$wrapper_path"
    if [[ -n "$binary_args" ]]; then
        echo "exec \"$binary_path\" $binary_args" >> "$wrapper_path"
    else
        echo "exec \"$binary_path\"" >> "$wrapper_path"
    fi

    chmod +x "$wrapper_path"
}

# Run workload with standard timing and monitoring
run_workload_standard() {
    local numa_args="${1:-"--cpunodebind=0 --membind=0"}"

    # Validate required variables
    if [[ -z "$WRAPPER" || -z "$TIMEFILE" || -z "$STDOUT" || -z "$STDERR" || -z "$PIDFILE" ]]; then
        echo "ERROR: Required variables not set. Call generate_workload_filenames first."
        return 1
    fi

    if [[ ! -f "$WRAPPER" ]]; then
        echo "ERROR: Wrapper script not found: $WRAPPER"
        echo "Call create_workload_wrapper first."
        return 1
    fi

    set +e # Disable error code checking so we can use &

    # Check if VMA recording is enabled
    if [[ "${VMA_RECORD:-0}" == "1" ]]; then
        echo "Starting workload with VMA recording..."
        # Run with record_vma.sh wrapper
        sudo numactl $numa_args \
            /usr/bin/time -v -o "$TIMEFILE" \
            "$CUR_PATH/scripts/vma/record_vma.sh" "$OUTPUT_DIR" \
            "$WRAPPER" \
            1> "$STDOUT" 2> "$STDERR" &
    else
        # run under numactl; time measures the wrapper -> execed binary
        sudo numactl $numa_args \
            /usr/bin/time -v -o "$TIMEFILE" \
            "$WRAPPER" \
            1> "$STDOUT" 2> "$STDERR" &
    fi

    # wait until wrapper has written pidfile (tiny loop is fine)
    local timeout=10  # 10 second timeout
    local count=0
    while [ ! -s "$PIDFILE" ] && [ $count -lt $((timeout * 100)) ]; do
        sleep 0.01
        ((count++))
    done
    set -e

    if [ ! -s "$PIDFILE" ]; then
        echo "ERROR: Timeout waiting for PID file: $PIDFILE"
        return 1
    fi

    # Set global workload_pid variable for use by run.sh wait_for_workload function
    workload_pid=$(cat "$PIDFILE")
    echo "workload_pid=$workload_pid"

    if [[ "${USE_CGROUP:-0}" == "1" ]]; then
        echo "Adding workload PID $workload_pid to experiment cgroup"
        if ! add_to_cgroup "$workload_pid"; then
            echo "Warning: failed to add workload to cgroup" >&2
        fi
    fi

    # optional: cleanup wrapper if you don't need it
    rm -f "$WRAPPER"
    rm -f "$PIDFILE"
}

# Complete workload execution function - combines all steps
execute_workload() {
    local workload_name="$1"
    local binary_path="$2"
    local binary_args="$3"
    local work_dir="$4"
    local numa_args="$5"

    echo "Executing workload: $workload_name"

    # Generate filenames
    generate_workload_filenames "$workload_name"

    # Create wrapper
    create_workload_wrapper "$binary_path" "$binary_args" "$work_dir"

    # Run workload
    run_workload_standard "$numa_args"
}

start_bwmon() {
    sudo $CUR_PATH/scripts/cipp-workspace/tools/bwmon 500 > "$BWMON" &
    sleep 1

}

stop_bwmon() {
    # Trying to kill individual pid not working.
    set -x
    sudo killall bwmon
    set +x
}

# Print workload execution info for debugging
print_workload_info() {
    local workload_name="$1"
    echo "=== Workload Execution Info ==="
    echo "Workload: $workload_name"
    echo "Iteration: ${CURRENT_ITERATION:-0}"
    echo "Output files:"
    echo "  Time: $TIMEFILE"
    echo "  Stdout: $STDOUT"
    echo "  Stderr: $STDERR"
    echo "  PID: $PIDFILE"
    echo "  Wrapper: $WRAPPER"
    echo "============================="
}
