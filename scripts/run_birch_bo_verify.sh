#!/bin/bash
# =============================================================================
# BIRCH BO Pipeline Verification Script
# =============================================================================
# Mini version of run_birch_bo_pipeline.sh for gapbs::bc.
# Uses minimal settings (1 BO iteration, small graph) to verify the
# pipeline works end-to-end.
# =============================================================================

set -euo pipefail

# Minimal settings for verification
export FAST_MEM="${FAST_MEM:-8G}"
export FAST_MEM_MB="${FAST_MEM_MB:-8192}"
export BO_ITERATIONS=1
export N_INITIAL_POINTS=1
export ITERATIONS_PER_TRIAL=1
export BACKUP_FAST_MEMORY="512M"

# Use smaller graph for faster verification
export GRAPH_SIZE="${GRAPH_SIZE:-23}"

WORKING_DIR="${WORKING_DIR:-$HOME/working}"
ARMS_DIR="${ARMS_DIR:-${WORKING_DIR}/arms}"
BO_ENGINE_DIR="${BO_ENGINE_DIR:-${WORKING_DIR}/bo_engine}"
WORKLOADS_DIR="${WORKLOADS_DIR:-${WORKING_DIR}/workloads}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-${ARMS_DIR}/libarms_kernel.so}"
BIRCH_INFO_PATH="${BIRCH_INFO_PATH:-${ARMS_DIR}/birch_info}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="results_birch_bo_verify_${TIMESTAMP}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE="gapbs"
WORKLOAD="bc"
TARGET_EXE="bc"

PASS=0
FAIL=0

check_file() {
    local path="$1"
    local desc="$2"
    if [[ -f "$path" ]]; then
        echo "  [PASS] ${desc}: ${path}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${desc}: ${path}"
        FAIL=$((FAIL + 1))
    fi
}

check_dir() {
    local path="$1"
    local desc="$2"
    if [[ -d "$path" ]]; then
        echo "  [PASS] ${desc}: ${path}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${desc}: ${path}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================================="
echo "BIRCH BO Pipeline Verification"
echo "  Result dir: ${RESULT_DIR}"
echo "=============================================="

mkdir -p "$RESULT_DIR"

# --- Step 1: Build BIRCH model ---
echo ""
echo "--- Step 1: Build BIRCH model ---"
CLUSTERING_DIR="${RESULT_DIR}/clustering"
BIRCH_MODEL_DIR="${RESULT_DIR}/birch_models"
mkdir -p "$CLUSTERING_DIR" "$BIRCH_MODEL_DIR"

BIRCH_MODEL="${BIRCH_MODEL_DIR}/${SUITE}_${WORKLOAD}_birch.bin"
BUILD_DIR="${CLUSTERING_DIR}/${SUITE}_${WORKLOAD}_build"

export HEMEMPOL="$LIB_ARMS_PATH"
export REGENT_FAST_MEMORY="$FAST_MEM"
export ARMS_POLICY="${ARMS_POLICY:-ARMS}"
export REGENT_VISUALIZATION=0
export REGENT_TARGET_EXE="$TARGET_EXE"

# Build run
unset REGENT_RO_BIRCH 2>/dev/null || true
unset BIRCH_INPUT 2>/dev/null || true
export BIRCH_OUTPUT="$BIRCH_MODEL"

"${WORKLOADS_DIR}/run.sh" -b "$SUITE" -w "$WORKLOAD" -o "$BUILD_DIR" -r 1 --use-cgroup

check_file "$BIRCH_MODEL" "BIRCH model created"

# --- Step 1b: RO BIRCH run ---
echo ""
echo "--- Step 1b: RO BIRCH run ---"
RO_DIR="${CLUSTERING_DIR}/${SUITE}_${WORKLOAD}_ro"
export REGENT_RO_BIRCH=1
export BIRCH_INPUT="$BIRCH_MODEL"
export BIRCH_OUTPUT="$BIRCH_MODEL"

"${WORKLOADS_DIR}/run.sh" -b "$SUITE" -w "$WORKLOAD" -o "$RO_DIR" -r 1 --use-cgroup

check_dir "$RO_DIR" "RO experiment output"

# --- Step 2: birch_info ---
echo ""
echo "--- Step 2: birch_info ---"
BIRCH_INFO_OUTPUT=$("$BIRCH_INFO_PATH" "$BIRCH_MODEL")
echo "  birch_info output: $BIRCH_INFO_OUTPUT"
NUM_CLUSTERS=$(echo "$BIRCH_INFO_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['num_clusters'])")
echo "  Detected ${NUM_CLUSTERS} clusters"

if [[ "$NUM_CLUSTERS" -gt 0 ]]; then
    echo "  [PASS] birch_info returned valid cluster count"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] birch_info returned invalid cluster count"
    FAIL=$((FAIL + 1))
fi

# --- Step 3: Generate BO configs ---
echo ""
echo "--- Step 3: Generate BO configs ---"
CONFIG_DIR="${RESULT_DIR}/configs"

python3 "${BO_ENGINE_DIR}/generate_cluster_bo_configs.py" \
    --birch-model "$BIRCH_MODEL" \
    --suite "$SUITE" --workload "$WORKLOAD" --target-exe "$TARGET_EXE" \
    --fast-mem-mb "$FAST_MEM_MB" \
    --output-dir "$CONFIG_DIR" \
    --birch-info-path "$BIRCH_INFO_PATH" \
    --lib-arms-kernel-path "$LIB_ARMS_PATH" \
    --workloads-dir "$WORKLOADS_DIR" \
    --results-base-dir "${RESULT_DIR}" \
    --bo-iterations 1 \
    --n-initial-points 1 \
    --backup-fast-memory "$BACKUP_FAST_MEMORY"

check_file "${CONFIG_DIR}/bo_cluster_parallel.yaml" "Parallel config generated"
check_file "${CONFIG_DIR}/bo_cluster_individual_0.yaml" "Individual config generated"

# --- Step 4: Parallel BO tuning (1 iteration) ---
echo ""
echo "--- Step 4: Parallel BO tuning (1 iteration) ---"
python3 "${BO_ENGINE_DIR}/run_cluster_bo.py" \
    --config "${CONFIG_DIR}/bo_cluster_parallel.yaml" \
    --bo-iterations 1 --n-initial-points 1 \
    --iterations-per-trial 1

check_file "${RESULT_DIR}/parallel_tuning/tuned_allocations.yaml" "Parallel tuned allocations"

# --- Step 5: Individual BO tuning cluster 0 (1 iteration) ---
echo ""
echo "--- Step 5: Individual BO tuning cluster 0 (1 iteration) ---"

python3 "${BO_ENGINE_DIR}/run_cluster_bo.py" \
    --config "${CONFIG_DIR}/bo_cluster_individual_0.yaml" \
    --bo-iterations 1 --n-initial-points 1 \
    --iterations-per-trial 1

check_file "${RESULT_DIR}/individual_tuning/cluster_0/tuned_allocations.yaml" "Individual tuned allocations"

# --- Summary ---
echo ""
echo "=============================================="
echo "Verification Summary"
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  Results in: ${RESULT_DIR}"
echo "=============================================="

if [[ "$FAIL" -gt 0 ]]; then
    echo "VERIFICATION FAILED"
    exit 1
else
    echo "VERIFICATION PASSED"
    exit 0
fi
