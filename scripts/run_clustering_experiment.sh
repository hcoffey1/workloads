#!/bin/bash
# =============================================================================
# REGENT Clustering (BIRCH) Experiment Harness
# =============================================================================
# Runs BIRCH clustering across multiple workloads. For each workload:
#   1. Build run: builds a BIRCH model from scratch
#   2. RO run: uses the built BIRCH model in read-only mode
# =============================================================================

set -u

# =============================================================================
# CONFIGURATION
# =============================================================================

FAST_MEM="${FAST_MEM:-32G}"
ITERATIONS="${ITERATIONS:-1}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-$HOME/working/arms/libarms_kernel.so}"
ARMS_POLICY="${ARMS_POLICY:-ARMS}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_BASE="${OUTPUT_BASE:-results_clustering_${TIMESTAMP}}"

BIRCH_MODEL_DIR="${OUTPUT_BASE}/birch_models"

# =============================================================================
# WORKLOAD REGISTRY
# =============================================================================
# Format: "suite:workload:target_exe"
# Comment out entries to skip workloads.

WORKLOADS=(
    "gapbs:bc:bc"
    "gapbs:bfs:bfs"
    "gapbs:pr:pr"
    "gapbs:pr_spmv:pr_spmv"
    "gapbs:cc:cc"
    "gapbs:cc_sv:cc_sv"
    "gapbs:sssp:sssp"
    "gapbs:tc:tc"
    "liblinear:liblinear:train"
    "merci:merci:eval_baseline"
    "xsbench:xsbench:XSBench"
    "cloverleaf:cloverleaf:clover_leaf"
    "silo:silo:dbtest"
)

# =============================================================================
# COMMON ENVIRONMENT
# =============================================================================

export HEMEMPOL="$LIB_ARMS_PATH"
export REGENT_FAST_MEMORY="$FAST_MEM"
export ARMS_POLICY="$ARMS_POLICY"
export REGENT_VISUALIZATION=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/../run.sh"

# =============================================================================
# FUNCTIONS
# =============================================================================

run_build_birch() {
    local suite="$1"
    local workload="$2"
    local target_exe="$3"
    local output_dir="$4"
    local birch_output="$5"

    echo "=========================================="
    echo "BUILD BIRCH: ${suite}/${workload}"
    echo "  Output dir:   ${output_dir}"
    echo "  BIRCH model:  ${birch_output}"
    echo "=========================================="

    # Fresh build: unset RO mode and input so BIRCH builds from scratch
    unset REGENT_RO_BIRCH
    unset BIRCH_INPUT

    export BIRCH_OUTPUT="$birch_output"
    export REGENT_TARGET_EXE="$target_exe"

    "$RUN_SH" -b "$suite" -w "$workload" -o "$output_dir" \
        -r "$ITERATIONS" --use-cgroup
}

run_ro_birch() {
    local suite="$1"
    local workload="$2"
    local target_exe="$3"
    local output_dir="$4"
    local birch_input="$5"

    echo "=========================================="
    echo "RO BIRCH: ${suite}/${workload}"
    echo "  Output dir:   ${output_dir}"
    echo "  BIRCH model:  ${birch_input}"
    echo "=========================================="

    export REGENT_RO_BIRCH=1
    export BIRCH_INPUT="$birch_input"
    export BIRCH_OUTPUT="$birch_input"
    export REGENT_TARGET_EXE="$target_exe"

    "$RUN_SH" -b "$suite" -w "$workload" -o "$output_dir" \
        -r "$ITERATIONS" --use-cgroup
}

# =============================================================================
# MAIN
# =============================================================================

mkdir -p "$OUTPUT_BASE"
mkdir -p "$BIRCH_MODEL_DIR"

echo "=============================================="
echo "REGENT Clustering Experiment"
echo "  Output base:  ${OUTPUT_BASE}"
echo "  BIRCH models: ${BIRCH_MODEL_DIR}"
echo "  Iterations:   ${ITERATIONS}"
echo "  Workloads:    ${#WORKLOADS[@]}"
echo "=============================================="

for entry in "${WORKLOADS[@]}"; do
    IFS=':' read -r suite workload target_exe <<< "$entry"

    birch_model="${BIRCH_MODEL_DIR}/${suite}_${workload}_birch.bin"
    build_dir="${OUTPUT_BASE}/${suite}_${workload}_build"
    ro_dir="${OUTPUT_BASE}/${suite}_${workload}_ro"

    # Step 1: Build BIRCH model
    run_build_birch "$suite" "$workload" "$target_exe" "$build_dir" "$birch_model"

    # Step 2: Read-only run using built model
    run_ro_birch "$suite" "$workload" "$target_exe" "$ro_dir" "$birch_model"
done

echo "=============================================="
echo "All clustering experiments completed!"
echo "Results in: ${OUTPUT_BASE}"
echo "=============================================="
