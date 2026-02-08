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
FAST_MEM="${FAST_MEM:-2G}"          # Fast tier size
SEQ_ARMS_SIZE="${SEQ_ARMS_SIZE:-128M}" # ARMS budget for sequential region (hybrid only)
ITERATIONS="${ITERATIONS:-10}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-$HOME/arms/libarms_kernel.so}"
ARMS_POLICY="${ARMS_POLICY:-ARMS}"  # Policy for control/base (ARMS or lru_ptscan)

# Output directory
OUTPUT_BASE="${OUTPUT_BASE:-results_interference}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

run_experiment() {
    local name="$1"
    local seq_delay="$2"
    local seq_runtime="$3"
    local zipf_delay="$4"
    local zipf_runtime="$5"
    local output_dir="$6"
    local policy="$7"  # "hybrid" or "control"

    echo "=================================================="
    echo "Running: $name ($policy)"
    echo "  Sequential: delay=${seq_delay}s, runtime=${seq_runtime}s"
    echo "  Zipfian:    delay=${zipf_delay}s, runtime=${zipf_runtime}s"
    echo "=================================================="

    mkdir -p "$output_dir"

    # Export configuration for the workload script
    export INTERFERENCE_DURATION=$DURATION
    export SEQ_REGIONS=$SEQ_REGIONS
    export SEQ_REGION_MB=$SEQ_REGION_MB
    export SEQ_THREADS=$SEQ_THREADS
    export SEQ_DELAY=$seq_delay
    export SEQ_RUNTIME=$seq_runtime
    export ZIPF_REGION_MB=$ZIPF_REGION_MB
    export ZIPF_THETA=$ZIPF_THETA
    export ZIPF_THREADS=$ZIPF_THREADS
    export ZIPF_DELAY=$zipf_delay
    export ZIPF_RUNTIME=$zipf_runtime
    export REGENT_ANNOTATION_FILE="/users/hjcoffey/workloads/${output_dir}/annotations.txt" # Save annotations for this run
    # export SEQ_VA_RANGE="${SEQ_VA_RANGE:-"0x7ffde3e00000-0x7ffee3dfffff"}" # Optional: hardcode sequential VA range

    local target_va_range="${SEQ_VA_RANGE:-"0x7ffde3e00000-0x7ffee3dfffff"}"

    if [[ "$policy" == "hybrid" ]]; then

    if [[ "$ARMS_POLICY" == "arms" ]]; then
        target_va_range="0x7ffddbe00000-0x7ffedbdfffff"
    elif [[ "$ARMS_POLICY" == "lru_ptscan" ]]; then
        target_va_range="0x7ffde3e00000-0x7ffee3dfffff"
    fi
        # Hybrid: ARMS applied only to sequential region (manual or hardcoded)
        #REGENT_VIS_DIR="/users/hjcoffey/workloads/$output_dir/vis" \
        #REGENT_VISUALIZATION=1 \
        SEQ_VA_RANGE="$target_va_range" \
        SEQ_ARMS_SIZE=$SEQ_ARMS_SIZE \
        ARMS_POLICY=$ARMS_POLICY \
        HYBRID_POLICY=${HYBRID_POLICY:-lru_ptscan} \
        REGENT_FAST_MEMORY=$FAST_MEM \
        HEMEMPOL=$LIB_ARMS_PATH \
        REGENT_ANNOTATION_FILE="${REGENT_ANNOTATION_FILE:-}" \
        /users/hjcoffey/workloads/run.sh -b micro_interference -w micro_interference -o "$output_dir" \
            -r $ITERATIONS --use-cgroup
            #-r $ITERATIONS -i pebs -s 500 --record-vma
    else
        # Control: Global policy (configured via ARMS_POLICY)
        echo "Policy: Control (Global $ARMS_POLICY)"
        #REGENT_VIS_DIR="/users/hjcoffey/workloads/$output_dir/vis" \
        #REGENT_VISUALIZATION=1 \
        ARMS_POLICY=$ARMS_POLICY \
        SEQ_VA_RANGE="" \
        HEMEMPOL=$LIB_ARMS_PATH \
        REGENT_FAST_MEMORY=$FAST_MEM \
        REGENT_ANNOTATION_FILE="${REGENT_ANNOTATION_FILE:-}" \
        /users/hjcoffey/workloads/run.sh -b micro_interference -w micro_interference -o "$output_dir" \
            -r $ITERATIONS --use-cgroup
            #-r $ITERATIONS -i pebs -s 500 --record-vma
    fi

    echo "Completed: $name ($policy)"
    echo ""
}

run_all_experiments() {
    local policy="$1"
    local config_suffix="${ARMS_POLICY:-ARMS}"
    if [[ "$policy" == "hybrid" ]]; then
        config_suffix="${config_suffix}_${HYBRID_POLICY:-lru_ptscan}_${SEQ_ARMS_SIZE}"
    fi
    local base_dir="$OUTPUT_BASE/${policy}_${config_suffix}"

    echo ""
    echo "###################################################"
    echo "# Running all experiments with policy: $policy"
    echo "###################################################"
    echo ""

    # Experiment 1: Both patterns for 60s (baseline)
    run_experiment "both_60s" \
        0 0 \
        0 0 \
        "$base_dir/exp1_both_60s" \
        "$policy"

    # Experiment 2: Zipfian delayed 2s, runs 2s. Sequential runs 5s.
#    run_experiment "zipf_delayed" \
#        0 0 \
#        2 2 \
#        "$base_dir/exp2_zipf_delayed" \
#        "$policy"
#
#    # Experiment 3: Sequential delayed 2s, runs 2s. Zipfian runs 5s.
#    run_experiment "seq_delayed" \
#        2 2 \
#        0 0 \
#        "$base_dir/exp3_seq_delayed" \
#        "$policy"
}

# =============================================================================
# MAIN
# =============================================================================

echo "=============================================="
echo "Micro Interference Experiment Suite"
echo "=============================================="
echo "Configuration:"
echo "  Sequential: ${SEQ_REGIONS} x ${SEQ_REGION_MB}MB = $((SEQ_REGIONS * SEQ_REGION_MB / 1024))GB"
echo "  Zipfian:    ${ZIPF_REGION_MB}MB = $((ZIPF_REGION_MB / 1024))GB"
echo "  Threads:    seq=${SEQ_THREADS}, zipf=${ZIPF_THREADS}"
echo "  Duration:   ${DURATION}s"
echo "  Iterations: ${ITERATIONS}"
echo ""
echo "ARMS Config:"
echo "  FAST_MEM:      ${FAST_MEM}"
echo "  SEQ_ARMS_SIZE: ${SEQ_ARMS_SIZE} (hybrid only)"
echo "=============================================="
echo ""

mkdir -p "$OUTPUT_BASE"

# =============================================================================
# RUN SCENARIOS
# =============================================================================

# 1. Controls
#echo "Running Control Scenarios..."
#for pol in "lru_ptscan"; do
for pol in "ARMS" "lru_ptscan"; do
    export ARMS_POLICY=$pol
    run_all_experiments "control"
done

# 2. Hybrids
echo "Running Hybrid Scenarios..."
##
 #Scenario A: Base=ARMS, Hybrid=lru_ptscan
export ARMS_POLICY="arms"
export HYBRID_POLICY="lru_ptscan"
for size in "128M" "256M" "512M" "1G"; do
    export SEQ_ARMS_SIZE="$size"
    run_all_experiments "hybrid"
done
#
# Scenario B: Base=lru_ptscan, Hybrid=ARMS
export ARMS_POLICY="lru_ptscan"
export HYBRID_POLICY="ARMS"
for size in "128M" "256M" "512M" "1G"; do
    export SEQ_ARMS_SIZE="$size"
    run_all_experiments "hybrid"
done

echo "=============================================="
echo "All experiments completed!"
echo "Results in: $OUTPUT_BASE"
echo "=============================================="
