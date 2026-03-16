#!/bin/bash
# =============================================================================
# HeMem Static Partitioning Experiment with micro_interference
# =============================================================================
# Compares three HeMem policy configurations:
#
#   1. hemem_split_tuned   — Two hemem instances per region, sequential gets
#                            lower (more reactive) thresholds
#   2. hemem_split_default — Two hemem instances per region, both use default
#                            HeMem thresholds (control)
#   3. hemem_single        — One hemem fallback instance over all memory
#
# Uses libarms_static.so with per-region policy configuration via deferred
# bounds.  Follows the same harness pattern as run_static_interference_experiment.sh.
#
# Usage:
#   ./scripts/run_hemem_interference_experiment.sh
#
# Environment overrides:
#   ITERATIONS            Number of iterations per config (default: 1)
#   FAST_MEM              Total fast memory budget (default: 6G)
#   LIB_ARMS_STATIC_PATH  Path to libarms_static.so
#   OUTPUT_BASE           Results root directory (default: results_hemem)
#   CONFIGS               Comma-separated configs to run (default: all three)
#   DURATION              Workload duration in seconds (default: 60)
#   SEQ_THREADS           Sequential threads (default: 4)
#   ZIPF_THREADS          Zipfian threads (default: 0 = use workload default)
#
# Output layout (compatible with plot_interference.py):
#   results_hemem/
#       hemem_split_tuned/
#           micro_interference_micro_interference_*_iter0_stdout.txt
#           numastat_iter0.txt
#       hemem_split_default/
#           ...
#       hemem_single/
#           ...
#
# Analyze:
#   python3 scripts/plot_interference.py --results-dir results_hemem \
#       --control hemem_split_default
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOADS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# CONFIGURATION
# =============================================================================

DURATION="${DURATION:-60}"
SEQ_REGIONS="${SEQ_REGIONS:-64}"
SEQ_REGION_MB="${SEQ_REGION_MB:-64}"
SEQ_THREADS="${SEQ_THREADS:-4}"
ZIPF_REGION_MB="${ZIPF_REGION_MB:-4096}"
ZIPF_THETA="${ZIPF_THETA:-0.8}"
ZIPF_THREADS="${ZIPF_THREADS:-4}"
ITERATIONS="${ITERATIONS:-2}"
FAST_MEM="${FAST_MEM:-2G}"

LIB_ARMS_STATIC_PATH="${LIB_ARMS_STATIC_PATH:-$HOME/working/arms/libarms_static.so}"
OUTPUT_BASE="${OUTPUT_BASE:-results_hemem}"
CONFIGS="${CONFIGS:-hemem_split_tuned,hemem_split_default,hemem_single}"

# =============================================================================
# CONFIG GENERATORS
# =============================================================================

# Generate a split hemem config with custom per-region thresholds.
# Args: config_path seq_budget zipf_budget
#       seq_hot_read seq_hot_write seq_cooling seq_interval
#       zipf_hot_read zipf_hot_write zipf_cooling zipf_interval
#       [fallback_policy fallback_budget]
generate_hemem_split_config() {
    local config_path="$1"
    local seq_budget="$2"
    local zipf_budget="$3"
    local seq_hot_read="$4"
    local seq_hot_write="$5"
    local seq_cooling="$6"
    local seq_interval="$7"
    local zipf_hot_read="$8"
    local zipf_hot_write="$9"
    local zipf_cooling="${10}"
    local zipf_interval="${11}"
    local fallback_pol="${12:-arms}"
    local fallback_budget="${13:-2G}"

    cat > "$config_path" <<EOF
[region]
name = Sequential
policy = hemem
start = 0x0
end = 0x0
fast_memory = $seq_budget
hot_read_threshold = $seq_hot_read
hot_write_threshold = $seq_hot_write
cooling_threshold = $seq_cooling
policy_interval_us = $seq_interval
migrate_rate = 10G

[region]
name = Zipfian
policy = hemem
start = 0x0
end = 0x0
fast_memory = $zipf_budget
hot_read_threshold = $zipf_hot_read
hot_write_threshold = $zipf_hot_write
cooling_threshold = $zipf_cooling
policy_interval_us = $zipf_interval
migrate_rate = 10G

[fallback]
name = Default
policy = $fallback_pol
fast_memory = $fallback_budget
EOF
}

# Generate a single hemem fallback config (no per-region splitting).
# Args: config_path fast_budget hot_read hot_write cooling interval
generate_hemem_single_config() {
    local config_path="$1"
    local fast_budget="$2"
    local hot_read="$3"
    local hot_write="$4"
    local cooling="$5"
    local interval="$6"

    cat > "$config_path" <<EOF
[fallback]
name = Global
policy = hemem
fast_memory = $fast_budget
hot_read_threshold = $hot_read
hot_write_threshold = $hot_write
cooling_threshold = $cooling
policy_interval_us = $interval
migrate_rate = 10G
EOF
}

# =============================================================================
# RUN HELPER
# =============================================================================

run_hemem_experiment() {
    local name="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=================================================="
    echo "HeMem Experiment: $name"
    echo "  Config:  $config_file"
    echo "  Output:  $output_dir"
    echo "=================================================="

    mkdir -p "$output_dir"

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

IFS=',' read -ra SELECTED <<< "$CONFIGS"

for cfg in "${SELECTED[@]}"; do
    output_dir="$OUTPUT_BASE/$cfg"
    config_file="$output_dir/regions.ini"
    mkdir -p "$output_dir"

    case "$cfg" in
        hemem_split_tuned)
            echo "Generating tuned split config (sequential: reactive, zipfian: default)..."
            generate_hemem_split_config "$config_file" \
                "256M" "1.75G" \
                4 2 5 5000 \
                8 4 10 10000
            ;;
        hemem_split_default)
            echo "Generating default split config (both regions: default thresholds)..."
            generate_hemem_split_config "$config_file" \
                "256M" "1.75G" \
                8 4 10 10000 \
                8 4 10 10000
            ;;
        hemem_single)
            echo "Generating single-instance config (global fallback)..."
            generate_hemem_single_config "$config_file" \
                "$FAST_MEM" 8 4 10 10000
            ;;
        *)
            echo "ERROR: Unknown config '$cfg'"
            echo "Available: hemem_split_tuned, hemem_split_default, hemem_single"
            exit 1
            ;;
    esac

    run_hemem_experiment "$cfg" "$config_file" "$output_dir"
done

echo "=============================================="
echo "All HeMem experiments completed!"
echo "Results in: $OUTPUT_BASE"
echo ""
echo "Analyze with:"
echo "  python3 scripts/plot_interference.py --results-dir $OUTPUT_BASE --control hemem_split_default"
echo "  python3 scripts/plot_micro_throughput.py --results-dir $OUTPUT_BASE"
echo "=============================================="
