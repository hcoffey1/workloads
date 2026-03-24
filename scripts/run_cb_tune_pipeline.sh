#!/bin/bash
# =============================================================================
# CB_MULTIPLIER Tuning Pipeline
# =============================================================================
# Tunes the ARMS CB_MULTIPLIER knob per BIRCH cluster policy for gapbs bc.
#
# Steps (handled by run_cb_tune_bo.py):
#   1. Build run — generates the BIRCH model
#   2. Cluster detection — birch_info parses the model
#   3. BO tuning — per-cluster CB_MULTIPLIER tuning (one cluster at a time)
#   4. Comparison — tuned config vs default ARMS, N iterations each
#
# All results go into a single timestamped directory under RESULTS_BASE_DIR.
#
# Usage:
#   ./run_cb_tune_pipeline.sh
#
# Override defaults via environment:
#   BIRCH_MODEL=/path/to/model.bin ./run_cb_tune_pipeline.sh
#   BO_ITERATIONS=10 COMPARISON_ITERATIONS=3 ./run_cb_tune_pipeline.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — override any of these via environment variables
# =============================================================================

WORKING_DIR="${WORKING_DIR:-$HOME/working}"
ARMS_DIR="${ARMS_DIR:-${WORKING_DIR}/arms}"
BO_ENGINE_DIR="${BO_ENGINE_DIR:-${WORKING_DIR}/bo_engine}"

# Paths
LIB_ARMS_PATH="${LIB_ARMS_PATH:-${ARMS_DIR}/libarms_kernel.so}"
BIRCH_INFO_PATH="${BIRCH_INFO_PATH:-${ARMS_DIR}/birch_info}"

# Workload
SUITE="${SUITE:-gapbs}"
WORKLOAD="${WORKLOAD:-bc}"
TARGET_EXE="${TARGET_EXE:-bc}"
FAST_MEM="${FAST_MEM:-8G}"
BACKUP_FAST_MEMORY="${BACKUP_FAST_MEMORY:-512M}"

# BIRCH model path (the build run will write this file)
BIRCH_MODEL="${BIRCH_MODEL:-${WORKING_DIR}/bo_engine/results_cb_tune/birch_models/${SUITE}_${WORKLOAD}_birch.bin}"

# BO settings
BO_ITERATIONS="${BO_ITERATIONS:-32}"
N_INITIAL_POINTS="${N_INITIAL_POINTS:-8}"
ITERATIONS_PER_TRIAL="${ITERATIONS_PER_TRIAL:-1}"
COMPARISON_ITERATIONS="${COMPARISON_ITERATIONS:-5}"

# Search space (passed as YAML inline override via config)
CB_MULTIPLIER_MIN="${CB_MULTIPLIER_MIN:-0.1}"
CB_MULTIPLIER_MAX="${CB_MULTIPLIER_MAX:-5.0}"

# Results will be placed under this directory (timestamped subdirectory created automatically)
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-${BO_ENGINE_DIR}/results_cb_tune}"

# =============================================================================
# SETUP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOADS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure BIRCH model directory exists
mkdir -p "$(dirname "$BIRCH_MODEL")"

# Write a temporary config YAML for this run
TMPCONFIG=$(mktemp /tmp/bo_cb_tune_XXXXXX.yaml)
trap 'rm -f "$TMPCONFIG"' EXIT

cat > "$TMPCONFIG" <<EOF
# Auto-generated CB_MULTIPLIER tuning config
workloads_dir: ${WORKLOADS_DIR}
lib_arms_kernel_path: ${LIB_ARMS_PATH}
birch_info_path: ${BIRCH_INFO_PATH}
results_base_dir: ${RESULTS_BASE_DIR}

suite: ${SUITE}
workload: ${WORKLOAD}
target_exe: ${TARGET_EXE}
fast_mem: "${FAST_MEM}"
iterations_per_trial: ${ITERATIONS_PER_TRIAL}

birch_model: ${BIRCH_MODEL}

backup_policy: arms
backup_fast_memory: "${BACKUP_FAST_MEMORY}"

result_parser: gapbs
minimize: true

bo_iterations: ${BO_ITERATIONS}
n_initial_points: ${N_INITIAL_POINTS}
acq_func: gp_hedge
random_state: 42

comparison_iterations: ${COMPARISON_ITERATIONS}

search_space:
  cb_multiplier: [${CB_MULTIPLIER_MIN}, ${CB_MULTIPLIER_MAX}]
EOF

# =============================================================================
# RUN
# =============================================================================

echo "============================================================"
echo "CB_MULTIPLIER Tuning Pipeline"
echo "  Workload:       ${SUITE}/${WORKLOAD}"
echo "  Fast memory:    ${FAST_MEM} (backup: ${BACKUP_FAST_MEMORY})"
echo "  BIRCH model:    ${BIRCH_MODEL}"
echo "  BO iterations:  ${BO_ITERATIONS} (${N_INITIAL_POINTS} initial points)"
echo "  Trial iters:    ${ITERATIONS_PER_TRIAL}"
echo "  Comparison:     ${COMPARISON_ITERATIONS} iterations each"
echo "  CB range:       [${CB_MULTIPLIER_MIN}, ${CB_MULTIPLIER_MAX}]"
echo "  Results base:   ${RESULTS_BASE_DIR}"
echo "============================================================"
echo ""

python3 "${BO_ENGINE_DIR}/run_cb_tune_bo.py" --config "$TMPCONFIG"
