#!/bin/bash

# ==============================================================================
# EXPERIMENT RUNNER - Clean and Refactored Version
# ==============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures
#set -x
#PS4='${LINENO}: '

#set -eE -o pipefail
trap 'echo "ERR: command \"$BASH_COMMAND\" failed at ${BASH_SOURCE}:${LINENO}" >&2' ERR


# ==============================================================================
# GLOBAL VARIABLES
# ==============================================================================
declare -g CUR_PATH DAMO_PATH PEBS_PATH PEBS_PIPE
declare -g SUITE WORKLOAD CONFIG_FILE INSTRUMENT OUTPUT_DIR ITERATIONS
declare -g SAMPLING_RATE AGG_RATE MIN_NUM_DAMO MAX_NUM_DAMO
declare -g DAMON_AUTO_ACCESS_BP DAMON_AUTO_AGGRS
declare -g hemem_policy workload_pid

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Function to display usage instructions
usage() {
    cat << EOF
Usage: $0 -b benchmark_suite -w workload -o output_dir [OPTIONS]

REQUIRED:
  -b benchmark_suite          Benchmark suite to run
  -w workload                 Workload name
  -o output_dir              Output directory for results

OPTIONAL:
  -f config_file.yaml        YAML configuration file for workload parameters
  -i instrumentation         Instrumentation tool: 'pebs', 'damon' (default: none)
  -r iterations              Number of iterations to run (default: 1)
  -s sampling_rate           Damon Sampling Rate in microseconds (default: 5000)
  -a aggregate_rate          Damon Aggregate Rate in milliseconds (default: 100)
  -n min_regions             Min number of Damon regions
  -m max_regions             Max number of Damon regions
  -x auto_access_bp          Damon auto access_bp parameter
  -y auto_aggrs              Damon auto aggregation parameter
  --record-vma               Enable VMA recording using record_vma.sh

EXAMPLES:
  $0 -b graph500 -w graph500 -o results/baseline
  $0 -b gapbs -w bfs -o results/test -i damon -s 1000 -a 50
  $0 -b xsbench -w xsbench -o results/multi -r 5  # Run 5 iterations
EOF
    exit 1
}

# Extract policy name from HEMEMPOL path
extract_policy() {
    local path="$1"
    case $(basename "$path") in
        libhemem.so) echo "libhemem" ;;
        libhemem-lru.so) echo "libhemem-lru" ;;
        libhemem-baseline.so) echo "libhemem-baseline" ;;
        *) echo "unknown" ;;
    esac
}

# Generate output filename with iteration number
generate_output_filename() {
    local base_name="$1"
    local extension="$2"
    local filename="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}"

    if [[ -n "$CURRENT_ITERATION" ]]; then
        filename+="_iter${CURRENT_ITERATION}"
    fi

    if [[ -n "$base_name" ]]; then
        filename+="_${base_name}"
    fi

    filename+=".${extension}"
    echo "$filename"
}

# Print configuration for debugging
print_config() {
    cat << EOF
=== EXPERIMENT CONFIGURATION ===
Suite:           $SUITE
Workload:        $WORKLOAD
Output Dir:      $OUTPUT_DIR
Config File:     ${CONFIG_FILE:-"(none)"}
Instrumentation: ${INSTRUMENT:-"(none)"}
VMA Recording:   ${VMA_RECORD:-0}
Iterations:      $ITERATIONS
Hemem Policy:    $hemem_policy
==================================
EOF
}

# ==============================================================================
# SYSTEM MANAGEMENT FUNCTIONS
# ==============================================================================

sys_init() {
    echo "Initializing system..."
    # Disable randomized va space for consistent memory layout
    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    # Drop page cache for clean memory state
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
}

sys_cleanup() {
    echo "Cleaning up system..."
    # Re-enable randomized va space
    echo 2 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
}

# ==============================================================================
# DAMON FUNCTIONS
# ==============================================================================

start_damo() {
    local output_file="$1" proc_pid="$2" sampling_period="$3" agg_period="$4"
    local min_num_region="$5" max_num_region="$6"

    echo "Starting DAMON monitoring (PID: $proc_pid, Output: $output_file)"

    local damo_cmd="sudo env PATH=$PATH damo record -s $sampling_period -a $agg_period -o $output_file"

    if [[ -n "$min_num_region" ]]; then
        damo_cmd+=" --monitoring_nr_regions_range $min_num_region $max_num_region"
    fi

    $damo_cmd $proc_pid &
}

start_damo_autotune() {
    local output_file="$1" proc_pid="$2" sampling_period="$3" agg_period="$4"
    local min_num_region="$5" max_num_region="$6"

    # Set defaults if not provided
    [[ -z "$DAMON_AUTO_ACCESS_BP" ]] && DAMON_AUTO_ACCESS_BP=4
    [[ -z "$DAMON_AUTO_AGGRS" ]] && DAMON_AUTO_AGGRS=100

    echo "Starting DAMON autotune (PID: $proc_pid, BP: $DAMON_AUTO_ACCESS_BP, AGGRS: $DAMON_AUTO_AGGRS)"

    local damo_cmd="sudo env PATH=$PATH damo record"
    damo_cmd+=" --monitoring_intervals_goal $DAMON_AUTO_ACCESS_BP $DAMON_AUTO_AGGRS 2000 8000000"
    damo_cmd+=" -s $sampling_period -a $agg_period -o $output_file"

    if [[ -n "$min_num_region" ]]; then
        damo_cmd+=" --monitoring_nr_regions_range $min_num_region $max_num_region"
    fi

    $damo_cmd $proc_pid &
}

stop_damo() {
    local output_file="$1"
    local text_output_file="${output_file%.dat}.damon.txt"
    local text_region_output_file="${output_file%.dat}.region.damon.txt"

    echo "Stopping DAMON and generating reports..."
    sudo env PATH=$PATH damo stop

    # Generate reports with error handling
    sleep 10
    if ! sudo env PATH=$PATH damo report heatmap --output raw --input "$output_file" \
         --resol 1000 1000 --draw_range all > "$text_output_file"; then
        echo "Warning: Failed to generate DAMON heatmap report"
    fi

    sleep 10
    if ! sudo env PATH=$PATH damo report access --raw_form --raw_number \
         --input "$output_file" > "$text_region_output_file"; then
        echo "Warning: Failed to generate DAMON access report"
    fi
}

# Generate DAMON output filename based on parameters
generate_damo_filename() {
    local base="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${SAMPLING_RATE}_${AGG_RATE}"

    if [[ -n "$MIN_NUM_DAMO" && -n "$MAX_NUM_DAMO" ]]; then
        base+="_${MIN_NUM_DAMO}r_${MAX_NUM_DAMO}r"
    fi

    if [[ -n "$DAMON_AUTO_AGGRS" ]]; then
        base+="_${DAMON_AUTO_ACCESS_BP}bp_${DAMON_AUTO_AGGRS}agg"
    fi

    # Add iteration number
    if [[ -n "$CURRENT_ITERATION" ]]; then
        base+="_iter${CURRENT_ITERATION}"
    fi

    echo "${base}_damon.dat"
}

# ==============================================================================
# PEBS FUNCTIONS
# ==============================================================================

start_pebs() {
    local output_file="$1" sampling_period="$2"
    local epoch_size=$((1000 * 1000))

    echo "Starting PEBS monitoring (Period: $sampling_period, Output: $output_file)"

    # Clean up any existing pipe
    [[ -p "$PEBS_PIPE" ]] && rm "$PEBS_PIPE"
    mkfifo "$PEBS_PIPE"

    sudo "${PEBS_PATH}/bin/pebs_periodic_reads.x" "$sampling_period" "$epoch_size" "$output_file" "$PEBS_PIPE" &
    echo $!
}

stop_pebs() {
    echo "Stopping PEBS monitoring..."
    sudo echo "q" > "$PEBS_PIPE" 2>/dev/null || true
    sudo rm -f "$PEBS_PIPE"
}

# ==============================================================================
# WORKLOAD MANAGEMENT FUNCTIONS
# ==============================================================================

validate_workload_script() {
    local suite_script="$1"

    if [[ ! -f "$suite_script" ]]; then
        echo "ERROR: Workload script $suite_script not found."
        exit 1
    fi

    # Source the script
    source "$suite_script"

    # Check required functions exist
    local required_functions=("run_${SUITE}" "build_${SUITE}" "config_${SUITE}" "clean_${SUITE}")

    for func in "${required_functions[@]}"; do
        if ! declare -f "$func" > /dev/null; then
            echo "ERROR: Required function $func not found in $suite_script"
            exit 1
        fi
    done

    echo "Workload script validated successfully"
}

setup_workload() {
    echo "Setting up workload: $SUITE/$WORKLOAD"

    # Run configuration
    config_${SUITE} "${CONFIG_FILE}" "${WORKLOAD}"

    # Build workload
    echo "Building workload..."
    build_${SUITE} "${WORKLOAD}"
}

run_workload() {
    echo "Running workload: $SUITE/$WORKLOAD"
    run_${SUITE} "${WORKLOAD}"
}

wait_for_workload() {
    echo "Waiting for workload to complete (PID: $workload_pid)..."
    tail --pid=$workload_pid -f /dev/null
}

cleanup_workload() {
    echo "Cleaning up workload..."
    clean_${SUITE}
}

# ==============================================================================
# INSTRUMENTATION ORCHESTRATION
# ==============================================================================

run_with_pebs() {
    sys_init

    local pebs_output="${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${SAMPLING_RATE}"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        pebs_output+="_iter${CURRENT_ITERATION}"
    fi
    pebs_output+="_samples.dat"

    start_pebs "$pebs_output" "$SAMPLING_RATE"

    run_workload
    wait_for_workload

    stop_pebs
    sys_cleanup
}

run_with_damon() {
    sys_init

    local damo_file
    damo_file=$(generate_damo_filename)

    run_workload

    # Set up region parameters
    if [[ -n "$MIN_NUM_DAMO" || -n "$MAX_NUM_DAMO" ]]; then
        [[ -z "$MAX_NUM_DAMO" ]] && MAX_NUM_DAMO="$MIN_NUM_DAMO"
        [[ -z "$MIN_NUM_DAMO" ]] && MIN_NUM_DAMO="$MAX_NUM_DAMO"
    fi

    # Start appropriate DAMON mode
    if [[ -n "$DAMON_AUTO_AGGRS" ]]; then
        start_damo_autotune "$damo_file" "$workload_pid" "$SAMPLING_RATE" "$AGG_RATE" "$MIN_NUM_DAMO" "$MAX_NUM_DAMO"
    else
        start_damo "$damo_file" "$workload_pid" "$SAMPLING_RATE" "$AGG_RATE" "$MIN_NUM_DAMO" "$MAX_NUM_DAMO"
    fi

    wait_for_workload
    stop_damo "$damo_file"

    sys_cleanup
}

run_without_instrumentation() {
    sys_init

    run_workload
    wait_for_workload

    sys_cleanup
}

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

# ==============================================================================
# VMA RECORDING FLAG SUPPORT
# ==============================================================================
# Add --record-vma flag to optionally wrap workload execution with record_vma.sh
# This flag is parsed and propagated to workload scripts via an environment variable.
# When enabled, workloads are wrapped with: record_vma.sh $OUTPUT_DIR <original_command>
main() {
    # Initialize global variables
    CUR_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    DAMO_PATH="$CUR_PATH/scripts/damo"
    PEBS_PATH="$CUR_PATH/scripts/PEBS_page_tracking"
    PEBS_PIPE="/tmp/pebs_pipe"

    # HeMem env variables, set to '' if not defined.
    : "${DRAMSIZE:=}"
    : "${HEMEMPOL:=}"
    : "${MIN_INTERPOSE_MEM_SIZE:=}"

    # Parse arguments
    # Parse arguments, add --record-vma flag
    RECORD_VMA=0
    ARGS=()
    for arg in "$@"; do
        if [[ "$arg" == "--record-vma" ]]; then
            RECORD_VMA=1
        else
            ARGS+=("$arg")
        fi
    done
    export RECORD_VMA
    . $CUR_PATH/scripts/parse_args.sh "${ARGS[@]}"
    print_cmd_args

    # Validate required arguments
    if [[ -z "${_arg_suite:-}" || -z "${_arg_workload:-}" || -z "${_arg_output_dir:-}" ]]; then
        echo "ERROR: Required arguments missing"
        usage
    fi

    export PATH="$DAMO_PATH:$PATH"

    # Set configuration from parsed arguments
    SUITE="$_arg_suite"
    WORKLOAD="$_arg_workload"
    CONFIG_FILE="$_arg_config_file"
    INSTRUMENT="$_arg_instrument"
    OUTPUT_DIR="$_arg_output_dir"
    ITERATIONS="$_arg_iterations"
    SAMPLING_RATE="$_arg_sampling_rate"
    AGG_RATE="$_arg_aggregate_rate"
    MIN_NUM_DAMO="$_arg_min_damon"
    MAX_NUM_DAMO="$_arg_max_damon"
    DAMON_AUTO_ACCESS_BP="$_arg_auto_access_bp"
    DAMON_AUTO_AGGRS="$_arg_auto_aggrs"

    # Extract policy and set up directories
    hemem_policy=$(extract_policy "${HEMEMPOL:-}")

    # Create output directory
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi

    # Validate and setup workload
    local suite_script="$CUR_PATH/scripts/workloads/${SUITE}.sh"
    validate_workload_script "$suite_script"

    print_config
    setup_workload

    if [[ "$RECORD_VMA" == "1" ]]; then
        echo "[INFO] Running workload with VMA recording enabled."
        export VMA_RECORD=1
    else
        export VMA_RECORD=0
    fi

    # Run iterations
    for ((iteration=0; iteration<ITERATIONS; iteration++)); do
        echo "=== Running iteration $iteration of $ITERATIONS ==="

        # Export current iteration for workload scripts to use
        export CURRENT_ITERATION=$iteration

        # Run with appropriate instrumentation
        case "$INSTRUMENT" in
            "pebs")
                echo "=== Running with PEBS instrumentation ==="
                run_with_pebs
                ;;
            "damon")
                echo "=== Running with DAMON instrumentation ==="
                run_with_damon
                ;;
            ""|"none")
                echo "=== Running without instrumentation ==="
                run_without_instrumentation
                ;;
            *)
                echo "ERROR: Unknown instrumentation option '$INSTRUMENT'"
                echo "Valid options: 'pebs', 'damon', or leave empty for none"
                exit 1
                ;;
        esac

        echo "=== Iteration $iteration completed ==="

        # Add a short delay between iterations to ensure clean separation
        if [[ $iteration -lt $((ITERATIONS-1)) ]]; then
            sleep 2
        fi
    done

    # Cleanup
    cleanup_workload
    echo "=== Experiment completed successfully ==="
}

# Run main function with all arguments
main "$@"
