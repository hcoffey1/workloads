#!/bin/bash
# =============================================================================
# Micro Interference Experiment Harness
# =============================================================================
# Compares hybrid policy (ARMS on sequential region only) vs control (global ARMS)
# across 3 interference scenarios.
#
# Experiments per policy:
#   1. Both patterns running for 60 seconds (baseline interference)
#   2. Zipfian delayed 20s, runs 20s. Sequential runs 60s.
#   3. Sequential delayed 20s, runs 20s. Zipfian runs 60s.
# =============================================================================

set -u

# =============================================================================
# CONFIGURATION
# =============================================================================

# Memory configuration: 16GB zipfian + 16GB sequential (8x2GB)
DURATION=60
SEQ_REGIONS=64
SEQ_REGION_MB=64
SEQ_THREADS=8
ZIPF_REGION_MB=4096
ZIPF_THETA=0.8
ZIPF_THREADS=8

# ARMS configuration
FAST_MEM="${FAST_MEM:-4G}"          # Fast tier size
#SEQ_ARMS_SIZE="${SEQ_ARMS_SIZE:-128M}" # ARMS budget for sequential region (hybrid only)
ITERATIONS="${ITERATIONS:-1}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-$HOME/arms/libarms_kernel.so}"
ARMS_POLICY="${ARMS_POLICY:-ARMS}"  # Policy for control/base (ARMS or lru_ptscan)


# Output directory
OUTPUT_BASE="${OUTPUT_BASE:-results_interference}"

# =============================================================================
# EXPERIMENT FUNCTIONS
# =============================================================================

launch_experiment() {
    local name="$1"
    local output_dir="$2"

    echo "--------------------------------------------------"
    echo "Experiment: $name"
    echo "Output: $output_dir"
    echo "--------------------------------------------------"

    mkdir -p "$output_dir"

    # Export common configuration
    export REGENT_VIS_DIR="/users/hjcoffey/workloads/$output_dir/vis"
    export REGENT_VISUALIZATION=1
    export INTERFERENCE_DURATION=$DURATION
    export SEQ_REGIONS=$SEQ_REGIONS
    export SEQ_REGION_MB=$SEQ_REGION_MB
    export SEQ_THREADS=$SEQ_THREADS
    # Delays can be customized per 'launch_experiment' call if we pass them,
    # but for now using globals or we can add args.
    # For now, let's assume global SEQ_DELAY/RUNTIME etc unless overridden by caller before calling this.
    export SEQ_DELAY=${SEQ_DELAY:-0}
    export SEQ_RUNTIME=${SEQ_RUNTIME:-0}
    export ZIPF_REGION_MB=$ZIPF_REGION_MB
    export ZIPF_THETA=$ZIPF_THETA
    export ZIPF_THREADS=$ZIPF_THREADS
    export ZIPF_DELAY=${ZIPF_DELAY:-0}
    export ZIPF_RUNTIME=${ZIPF_RUNTIME:-0}

    export REGENT_ANNOTATION_FILE="/users/hjcoffey/workloads/${output_dir}/annotations.txt"
    export REGENT_TARGET_EXE="micro_interference"
    #export REGENT_TARGET_EXE="bc"

    #/users/hjcoffey/workloads/run.sh -b gapbs -w bc -o "$output_dir" \
    /users/hjcoffey/workloads/run.sh -b micro_interference -w micro_interference -o "$output_dir" \
            -r $ITERATIONS --use-cgroup
}

run_control_experiment() {
    local name="$1"
    local policy="$2"
    local output_dir="$3"

    echo "=== Running CONTROL Experiment: $name ($policy) ==="

    # Reset REGENT specific envs just in case
    unset REGENT_REGIONS
    unset REGENT_NUM_REGIONS
    unset SEQ_VA_RANGE

    export ARMS_POLICY=$policy
    export HEMEMPOL=$LIB_ARMS_PATH
    export REGENT_FAST_MEMORY=$FAST_MEM

    launch_experiment "$name" "$output_dir"
}

run_hybrid_2region_experiment() {
    local name="$1"
    local seq_policy="$2"    # Policy for Sequential Region
    local seq_size="$3"      # Budget for Sequential Region
    local zipf_policy="$4"   # Policy for Zipfian Region
    local zipf_size="$5"     # Budget for Zipfian Region
    local output_dir="$6"

    echo "=== Running HYBRID 2-REGION Experiment: $name ==="

    local target_va_range="0x7ffde3e00000-0x7ffee3dfffff"

    # Layout:
    # Region 0: Sequential -> seq_policy : seq_size
    # Region 1: Zipfian    -> zipf_policy : zipf_size

    export REGENT_REGIONS="${seq_policy}:${target_va_range}:${seq_size};${zipf_policy}:0-0:${zipf_size}"
    export REGENT_NUM_REGIONS=2

    export ARMS_POLICY="hybrid"
    export HEMEMPOL=$LIB_ARMS_PATH
    export REGENT_FAST_MEMORY=$FAST_MEM


    launch_experiment "$name" "$output_dir"
}

run_hybrid_3region_experiment() {
    local name="$1"
    local seq_policy="$2"
    local seq_size="$3"
    local zipf1_policy="$4"
    local zipf1_size="$5"
    local zipf2_policy="$6"
    local zipf2_size="$7"
    local output_dir="$8"

    echo "=== Running HYBRID 3-REGION Experiment: $name ==="

    local target_va_range="0x7ffde3e00000-0x7ffee3dfffff"

    # Layout:
    # Region 0: Seq   -> seq_policy : seq_size
    # Region 1: Zipf1 -> zipf1_policy : zipf1_size
    # Region 2: Zipf2 -> zipf2_policy : zipf2_size

    export REGENT_REGIONS="${seq_policy}:${target_va_range}:${seq_size};${zipf1_policy}:0-0:${zipf1_size};${zipf2_policy}:0-0:${zipf2_size}"
    export REGENT_NUM_REGIONS=3

    export HEMEMPOL=$LIB_ARMS_PATH
    export REGENT_FAST_MEMORY=$FAST_MEM

    launch_experiment "$name" "$output_dir"
}
# =============================================================================

mkdir -p "$OUTPUT_BASE"

# =============================================================================
# RUN SCENARIOS
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Controls (Global Policy)
# ---------------------------------------------------------------------------
echo "Running Control Scenarios..."
for pol in "ARMS" "lru_ptscan"; do
    run_control_experiment "control_${pol}" "$pol" "$OUTPUT_BASE/control_${pol}"
done

# ---------------------------------------------------------------------------
# 2. Hybrid 2-Region Experiments
# ---------------------------------------------------------------------------
echo "Running Hybrid 2-Region Scenario (ARMS / ARMS)..."
run_hybrid_2region_experiment "hybrid_2reg_arms_arms" \
    "ARMS" "256M" "ARMS" "1.75G" \
    "$OUTPUT_BASE/hybrid_2reg_arms_arms"

echo "Running Hybrid 2-Region Scenario (lru_ptscan / ARMS)..."
run_hybrid_2region_experiment "hybrid_2reg_lru_arms" \
    "lru_ptscan" "256M" "ARMS" "1.75G" \
    "$OUTPUT_BASE/hybrid_2reg_lru_arms"

echo "Running Hybrid 2-Region Scenario (ARMS / lru_ptscan)..."
run_hybrid_2region_experiment "hybrid_2reg_arms_lru" \
    "ARMS" "256M" "lru_ptscan" "1.75G" \
    "$OUTPUT_BASE/hybrid_2reg_arms_lru"

echo "Running Hybrid 2-Region Scenario (arms_short / arms_long)..."
run_hybrid_2region_experiment "hybrid_2reg_arms_short_arms_long" \
    "arms_short" "256M" "arms_long" "1.75G" \
    "$OUTPUT_BASE/hybrid_2reg_arms_short_arms_long"

echo "=============================================="
echo "All experiments completed!"
echo "Results in: $OUTPUT_BASE"
echo "=============================================="
