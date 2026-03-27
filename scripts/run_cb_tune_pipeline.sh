#!/bin/bash
# =============================================================================
# ARMS Knob Tuning Pipeline
# =============================================================================
# Tunes ARMS knobs (CB_MULTIPLIER, PEBS_KSWAPD_INTERVAL_BIG, HIST_BIAS_RECN)
# per BIRCH cluster policy using Bayesian Optimization.
#
# Steps (handled by run_cb_tune_bo.py):
#   1. Build run — generates the BIRCH model (stored in timestamped results dir)
#   2. Cluster detection — birch_info parses the model
#   3. BO tuning — per-cluster knob tuning (one cluster at a time)
#   4. Comparison — tuned config vs default ARMS, N iterations each
#
# All results go into a single timestamped directory under RESULTS_BASE_DIR.
#
# Usage:
#   ./run_cb_tune_pipeline.sh
#
# Override defaults via environment:
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

# BO settings
BO_ITERATIONS="${BO_ITERATIONS:-16}"
N_INITIAL_POINTS="${N_INITIAL_POINTS:-8}"
ITERATIONS_PER_TRIAL="${ITERATIONS_PER_TRIAL:-1}"
COMPARISON_ITERATIONS="${COMPARISON_ITERATIONS:-5}"

# Search space bounds
CB_MULTIPLIER_MIN="${CB_MULTIPLIER_MIN:-0.1}"
CB_MULTIPLIER_MAX="${CB_MULTIPLIER_MAX:-5.0}"
PEBS_KSWAPD_INTERVAL_BIG_MIN="${PEBS_KSWAPD_INTERVAL_BIG_MIN:-100000}"
PEBS_KSWAPD_INTERVAL_BIG_MAX="${PEBS_KSWAPD_INTERVAL_BIG_MAX:-5000000}"
HIST_BIAS_RECN_MIN="${HIST_BIAS_RECN_MIN:-0.1}"
HIST_BIAS_RECN_MAX="${HIST_BIAS_RECN_MAX:-0.9}"

# Results will be placed under this directory (timestamped subdirectory created automatically)
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-${BO_ENGINE_DIR}/results_cb_tune}"

# =============================================================================
# SETUP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOADS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Write a temporary config YAML for this run
TMPCONFIG=$(mktemp /tmp/bo_cb_tune_XXXXXX.yaml)
trap 'rm -f "$TMPCONFIG"' EXIT

cat > "$TMPCONFIG" <<EOF
# Auto-generated ARMS knob tuning config
workloads_dir: ${WORKLOADS_DIR}
lib_arms_kernel_path: ${LIB_ARMS_PATH}
birch_info_path: ${BIRCH_INFO_PATH}
results_base_dir: ${RESULTS_BASE_DIR}

suite: ${SUITE}
workload: ${WORKLOAD}
target_exe: ${TARGET_EXE}
fast_mem: "${FAST_MEM}"
iterations_per_trial: ${ITERATIONS_PER_TRIAL}

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
  pebs_kswapd_interval_big: [${PEBS_KSWAPD_INTERVAL_BIG_MIN}, ${PEBS_KSWAPD_INTERVAL_BIG_MAX}]
  hist_bias_recn: [${HIST_BIAS_RECN_MIN}, ${HIST_BIAS_RECN_MAX}]
EOF

# =============================================================================
# RUN
# =============================================================================

echo "============================================================"
echo "ARMS Knob Tuning Pipeline"
echo "  Workload:       ${SUITE}/${WORKLOAD}"
echo "  Fast memory:    ${FAST_MEM} (backup: ${BACKUP_FAST_MEMORY})"
echo "  BO iterations:  ${BO_ITERATIONS} (${N_INITIAL_POINTS} initial points)"
echo "  Trial iters:    ${ITERATIONS_PER_TRIAL}"
echo "  Comparison:     ${COMPARISON_ITERATIONS} iterations each"
echo "  CB range:       [${CB_MULTIPLIER_MIN}, ${CB_MULTIPLIER_MAX}]"
echo "  Interval range: [${PEBS_KSWAPD_INTERVAL_BIG_MIN}, ${PEBS_KSWAPD_INTERVAL_BIG_MAX}] us"
echo "  Hist bias range:[${HIST_BIAS_RECN_MIN}, ${HIST_BIAS_RECN_MAX}]"
echo "  Results base:   ${RESULTS_BASE_DIR}"
echo "============================================================"
echo ""

python3 "${BO_ENGINE_DIR}/run_cb_tune_bo.py" --config "$TMPCONFIG"
