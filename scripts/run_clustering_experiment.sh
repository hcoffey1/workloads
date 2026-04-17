#!/bin/bash
# =============================================================================
# REGENT Clustering (BIRCH) Experiment Harness
# =============================================================================
# Runs BIRCH clustering across multiple workloads under two clustering
# configurations:
#   - hot:      ENABLE_COLDNESS_DURATION=0 (1D centroids)
#   - hot_cold: ENABLE_COLDNESS_DURATION=1 (2D centroids)
#
# For each phase, arms is rebuilt with the appropriate compile-time flag and
# the resulting libarms_kernel.so is copied to a phase-tagged path so the
# second build can't clobber the first.
#
# For each workload in each phase, a BUILD-only run is performed (RO step is
# intentionally left commented out below).
# =============================================================================

set -u

# =============================================================================
# CONFIGURATION
# =============================================================================

FAST_MEM="${FAST_MEM:-32G}"
ITERATIONS="${ITERATIONS:-1}"
ARMS_DIR="${ARMS_DIR:-$HOME/working/arms}"
ARMS_LIB="libarms_kernel.so"
ARMS_POLICY="${ARMS_POLICY:-ARMS}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_BASE="${OUTPUT_BASE:-results_clustering_${TIMESTAMP}}"

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

export REGENT_FAST_MEMORY="$FAST_MEM"
export ARMS_POLICY="$ARMS_POLICY"
export REGENT_VISUALIZATION=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/../run.sh"

# =============================================================================
# FUNCTIONS
# =============================================================================

build_arms() {
    local coldness_flag="$1"
    local dest_path="$2"

    echo "=========================================="
    echo "BUILD ARMS: ENABLE_COLDNESS_DURATION=${coldness_flag}"
    echo "  Dest:  ${dest_path}"
    echo "=========================================="

    (cd "$ARMS_DIR" && make clean && make -j ENABLE_COLDNESS_DURATION="$coldness_flag")
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "ERROR: arms build failed (ENABLE_COLDNESS_DURATION=${coldness_flag})" >&2
        exit $rc
    fi

    cp "${ARMS_DIR}/${ARMS_LIB}" "$dest_path"
    echo "  Copied $(basename "$dest_path")"
}

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

run_phase() {
    local label="$1"
    local coldness_flag="$2"

    local lib_tagged="${OUTPUT_BASE}/libarms_kernel_${label}.so"
    build_arms "$coldness_flag" "$lib_tagged"

    export LIB_ARMS_PATH="$lib_tagged"
    export HEMEMPOL="$lib_tagged"

    local phase_base="${OUTPUT_BASE}/${label}"
    local birch_model_dir="${phase_base}/birch_models"
    mkdir -p "$phase_base" "$birch_model_dir"

    echo "=============================================="
    echo "Phase: ${label} (ENABLE_COLDNESS_DURATION=${coldness_flag})"
    echo "  Library:      ${lib_tagged}"
    echo "  Output base:  ${phase_base}"
    echo "  BIRCH models: ${birch_model_dir}"
    echo "=============================================="

    for entry in "${WORKLOADS[@]}"; do
        IFS=':' read -r suite workload target_exe <<< "$entry"

        local birch_model="${birch_model_dir}/${suite}_${workload}_birch.bin"
        local build_dir="${phase_base}/${suite}_${workload}_build"
        local ro_dir="${phase_base}/${suite}_${workload}_ro"

        # Step 1: Build BIRCH model
        run_build_birch "$suite" "$workload" "$target_exe" "$build_dir" "$birch_model"

        # Step 2: Read-only run using built model
        # run_ro_birch "$suite" "$workload" "$target_exe" "$ro_dir" "$birch_model"
    done
}

# =============================================================================
# MAIN
# =============================================================================

mkdir -p "$OUTPUT_BASE"

echo "=============================================="
echo "REGENT Clustering Experiment"
echo "  Output base:  ${OUTPUT_BASE}"
echo "  Iterations:   ${ITERATIONS}"
echo "  Workloads:    ${#WORKLOADS[@]}"
echo "=============================================="

run_phase "hot"      0
run_phase "hot_cold" 1

# =============================================================================
# CROSS-WORKLOAD PLOTTING
# =============================================================================

CROSS_PLOT_SCRIPT="${ARMS_DIR}/scripts/plot_centroids_cross.py"
if command -v conda >/dev/null 2>&1; then
    echo "=============================================="
    echo "Generating cross-workload centroid plots ..."
    echo "=============================================="
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate dataVis
    python3 "$CROSS_PLOT_SCRIPT" "$OUTPUT_BASE"
    conda deactivate
else
    echo "WARNING: conda not on PATH; skipping cross-workload plotting."
    echo "         To plot manually:"
    echo "           conda activate dataVis"
    echo "           python3 ${CROSS_PLOT_SCRIPT} ${OUTPUT_BASE}"
fi

echo "=============================================="
echo "All clustering experiments completed!"
echo "  Hot phase results:      ${OUTPUT_BASE}/hot"
echo "  Hot+Cold phase results: ${OUTPUT_BASE}/hot_cold"
echo "  Cross-workload outputs:"
echo "    ${OUTPUT_BASE}/hot/centroids_cross_workload.png"
echo "    ${OUTPUT_BASE}/hot/centroids_cross_workload.csv"
echo "    ${OUTPUT_BASE}/hot_cold/centroids_cross_workload.png"
echo "    ${OUTPUT_BASE}/hot_cold/centroids_cross_workload.csv"
echo "=============================================="
