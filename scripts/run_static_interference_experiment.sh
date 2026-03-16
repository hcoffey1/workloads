#!/bin/bash
# =============================================================================
# Static ARMS Partitioning Experiment with micro_interference
# =============================================================================
# Uses libarms_static.so with per-region policy configuration.
# Each memory region (sequential and zipfian) gets its own independent ARMS
# policy instance via a static config file with deferred bounds.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOADS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# CONFIGURATION
# =============================================================================

DURATION=60
SEQ_REGIONS=64
SEQ_REGION_MB=64
SEQ_THREADS=4
ZIPF_REGION_MB=4096
ZIPF_THETA=0.8
ZIPF_THREADS=0
ITERATIONS="${ITERATIONS:-1}"
FAST_MEM="${FAST_MEM:-6G}"

LIB_ARMS_STATIC_PATH="${LIB_ARMS_STATIC_PATH:-$HOME/working/arms/libarms_static.so}"
OUTPUT_BASE="${OUTPUT_BASE:-results_static}"

# =============================================================================
# FUNCTIONS
# =============================================================================

generate_static_config() {
    local config_path="$1"
    local seq_policy="$2"
    local seq_budget="$3"
    local zipf_policy="$4"
    local zipf_budget="$5"
    local fallback_pol="${6:-arms}"
    local fallback_budget="${7:-2G}"

    cat > "$config_path" <<EOF
[region]
name = Sequential
policy = $seq_policy
start = 0x0
end = 0x0
fast_memory = $seq_budget

[region]
name = Zipfian
policy = $zipf_policy
start = 0x0
end = 0x0
fast_memory = $zipf_budget

[fallback]
name = Default
policy = $fallback_pol
fast_memory = $fallback_budget
EOF
}

run_static_experiment() {
    local name="$1"
    local seq_policy="$2"
    local seq_budget="$3"
    local zipf_policy="$4"
    local zipf_budget="$5"
    local output_dir="$6"

    echo "=================================================="
    echo "Static Experiment: $name"
    echo "  Sequential: policy=$seq_policy budget=$seq_budget"
    echo "  Zipfian:    policy=$zipf_policy budget=$zipf_budget"
    echo "  Output:     $output_dir"
    echo "=================================================="

    mkdir -p "$output_dir"

    # Generate static config
    local config_file="$output_dir/regions.ini"
    generate_static_config "$config_file" \
        "$seq_policy" "$seq_budget" "$zipf_policy" "$zipf_budget"

    # Clean stale bounds files
    rm -rf /tmp/regent

    # Set environment for static mode
    export HEMEMPOL="$LIB_ARMS_STATIC_PATH"
    export REGENT_STATIC_CONFIG="$config_file"
    export REGENT_FAST_MEMORY="$FAST_MEM"
    export REGENT_NUM_REGIONS=2
    export REGENT_VISUALIZATION=1
    export REGENT_VIS_DIR="$WORKLOADS_DIR/$output_dir/vis"
    export REGENT_TARGET_EXE="micro_interference"
    export REGENT_ANNOTATION_FILE="$WORKLOADS_DIR/${output_dir}/annotations.txt"

    # Workload params
    export INTERFERENCE_DURATION=$DURATION
    export SEQ_REGIONS=$SEQ_REGIONS
    export SEQ_REGION_MB=$SEQ_REGION_MB
    export SEQ_THREADS=$SEQ_THREADS
    export ZIPF_REGION_MB=$ZIPF_REGION_MB
    export ZIPF_THETA=$ZIPF_THETA
    export ZIPF_THREADS=$ZIPF_THREADS
    export SEQ_DELAY=0 SEQ_RUNTIME=0
    export ZIPF_DELAY=0 ZIPF_RUNTIME=0

    # Unset kernel-mode vars that would conflict
    unset REGENT_REGIONS 2>/dev/null || true
    unset ARMS_POLICY 2>/dev/null || true

    "$WORKLOADS_DIR/run.sh" -b micro_interference \
        -w micro_interference -o "$output_dir" \
        -r $ITERATIONS --use-cgroup
}

# =============================================================================
# RUN EXPERIMENTS
# =============================================================================

mkdir -p "$OUTPUT_BASE"

# Baseline: both regions use standard ARMS
echo "Running static ARMS/ARMS experiment..."
run_static_experiment "static_arms_arms" \
    "arms" "256M" "arms" "1.75G" \
    "$OUTPUT_BASE/static_arms_arms"

# Specialized: arms_short for sequential, arms_long for zipfian
echo "Running static arms_short/arms_long experiment..."
run_static_experiment "static_short_long" \
    "arms_short" "256M" "arms_long" "1.75G" \
    "$OUTPUT_BASE/static_short_long"

echo "=============================================="
echo "All static experiments completed!"
echo "Results in: $OUTPUT_BASE"
echo "=============================================="
