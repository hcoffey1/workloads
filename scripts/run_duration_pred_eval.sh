#!/bin/bash
# =============================================================================
# Duration-Prediction vs ARMS Evaluation Harness
# =============================================================================
# Builds libarms_kernel.so and runs gapbs bc through workloads/run.sh with
# two policies (via REGENT_POLICY env var):
#
#   1) arms          — baseline ARMS policy
#   2) duration_pred — hot-duration-based tiering policy
#
# Both run with REGENT_NO_CLUSTERING=1 (single policy over entire VA space).
#
# Supports sweeping across multiple fast-memory tier sizes via FAST_MEM_SIZES.
# Collects per-iteration Average Time from stdout logs and writes a long-format
# CSV suitable for plot_duration_pred_comparison.py.
#
# Override defaults via environment variables (see CONFIGURATION block).
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — override any of these via environment variables
# =============================================================================

WORKING_DIR="${WORKING_DIR:-$HOME/working}"
ARMS_DIR="${ARMS_DIR:-${WORKING_DIR}/arms}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-${ARMS_DIR}/libarms_kernel.so}"

SUITE="${SUITE:-gapbs}"
WORKLOAD="${WORKLOAD:-bc}"
TARGET_EXE="${TARGET_EXE:-bc}"
ITERATIONS="${ITERATIONS:-3}"

RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-${WORKING_DIR}/workloads/results_duration_pred_eval}"

# Multi-size sweep: space-separated list of fast-memory sizes.
# Set to a single value for a quick run.
FAST_MEM_SIZES="${FAST_MEM_SIZES:-0.5G 1G 1.5G 2G 3G 4G 8G}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/../run.sh"

# Convert FAST_MEM_SIZES string to a bash array
read -ra SIZE_ARRAY <<< "$FAST_MEM_SIZES"

# Helper: convert a size label like "0.5G" or "512M" to numeric GB
size_to_gb() {
    local s="$1"
    if [[ "$s" =~ ^([0-9.]+)[Gg]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^([0-9.]+)[Mm]$ ]]; then
        awk "BEGIN {printf \"%.4f\", ${BASH_REMATCH[1]} / 1024}"
    else
        echo "$s"  # assume already numeric GB
    fi
}

# =============================================================================
# STEP 1: Build libarms_kernel.so
# =============================================================================

echo "============================================================"
echo "[eval] Duration-Pred vs ARMS (multi-size sweep)"
echo "  Workload:   ${SUITE}/${WORKLOAD}"
echo "  Sizes:      ${FAST_MEM_SIZES}  (${#SIZE_ARRAY[@]} sizes)"
echo "  Iterations: ${ITERATIONS}"
echo "  Results:    ${RESULTS_BASE_DIR}"
echo "============================================================"

echo "[eval] Building libarms_kernel.so..."
make -C "$ARMS_DIR" clean
make -C "$ARMS_DIR" -j"$(nproc)"
if [[ ! -f "$LIB_ARMS_PATH" ]]; then
    echo "[eval] ERROR: Build failed — ${LIB_ARMS_PATH} not found" >&2
    exit 1
fi

# =============================================================================
# STEP 2: Run layout — one timestamped dir, with per-size subdirs
# =============================================================================

RUN_DIR="${RESULTS_BASE_DIR}/$(date +%Y%m%d_%H%M%S)"
echo "[eval] Run directory: ${RUN_DIR}"

# Create subdirs for every size
for sz in "${SIZE_ARRAY[@]}"; do
    mkdir -p "${RUN_DIR}/${sz}/arms" "${RUN_DIR}/${sz}/duration_pred"
done

# Shared env for all runs — single-policy mode, no clustering
export HEMEMPOL="$LIB_ARMS_PATH"
export REGENT_TARGET_EXE="$TARGET_EXE"
export REGENT_VISUALIZATION=0
export REGENT_NO_CLUSTERING=1
unset REGENT_STATIC_CONFIG 2>/dev/null || true

# --- Loop over sizes ---------------------------------------------------------
for sz_idx in "${!SIZE_ARRAY[@]}"; do
    sz="${SIZE_ARRAY[$sz_idx]}"
    echo ""
    echo "============================================================"
    echo "[eval] Size ${sz}  ($((sz_idx + 1))/${#SIZE_ARRAY[@]})"
    echo "============================================================"

    export REGENT_FAST_MEMORY="$sz"

    # --- Run 1: ARMS (baseline) ---------------------------------------------
    echo ""
    echo "[eval] === ${sz} — Run 1: ARMS ==="
    export REGENT_POLICY=arms
    "$RUN_SH" -b "$SUITE" -w "$WORKLOAD" \
        -o "${RUN_DIR}/${sz}/arms" \
        -r "$ITERATIONS" \
        --use-cgroup

    # --- Run 2: DURATION_PRED -----------------------------------------------
    echo ""
    echo "[eval] === ${sz} — Run 2: DURATION_PRED ==="
    export REGENT_POLICY=duration_pred
    "$RUN_SH" -b "$SUITE" -w "$WORKLOAD" \
        -o "${RUN_DIR}/${sz}/duration_pred" \
        -r "$ITERATIONS" \
        --use-cgroup
done

# =============================================================================
# STEP 3: Extract Average Time -> long-format CSV
# =============================================================================

CSV="${RUN_DIR}/iteration_times.csv"
echo "fast_mem,fast_mem_gb,config,iteration,avg_time_seconds" > "$CSV"

extract_avg_times() {
    local config="$1"
    local dir="$2"
    local fast_mem_label="$3"
    local fast_mem_gb="$4"
    local any_found=0

    for stdout_file in "$dir"/*_iter*_stdout.txt; do
        [[ -f "$stdout_file" ]] || continue

        # Parse iteration number from filename (e.g., ..._iter3_stdout.txt -> 3)
        local base
        base=$(basename "$stdout_file")
        local iter
        iter=$(echo "$base" | sed -n 's/.*_iter\([0-9]\+\)_stdout\.txt$/\1/p')
        [[ -z "$iter" ]] && iter=0

        # Extract "Average Time: X.XXXXX" — one per iteration
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*Average[[:space:]]+Time:[[:space:]]+([0-9]+\.[0-9]+) ]]; then
                echo "${fast_mem_label},${fast_mem_gb},${config},${iter},${BASH_REMATCH[1]}" >> "$CSV"
                any_found=1
            fi
        done < "$stdout_file"
    done

    if [[ $any_found -eq 0 ]]; then
        echo "[eval] WARNING: ${config} (${fast_mem_label}) has no Average Time rows" >&2
    fi
}

for sz in "${SIZE_ARRAY[@]}"; do
    gb=$(size_to_gb "$sz")
    extract_avg_times "arms"          "${RUN_DIR}/${sz}/arms"          "$sz" "$gb"
    extract_avg_times "duration_pred" "${RUN_DIR}/${sz}/duration_pred" "$sz" "$gb"
done

# =============================================================================
# STEP 4: Write run metadata
# =============================================================================

META="${RUN_DIR}/run_metadata.txt"
{
    echo "timestamp: $(date -Iseconds)"
    echo "hostname:  $(hostname)"
    if command -v git >/dev/null 2>&1; then
        if git -C "$ARMS_DIR" rev-parse HEAD >/dev/null 2>&1; then
            echo "git_head:  $(git -C "$ARMS_DIR" rev-parse HEAD)"
            echo "git_status:"
            git -C "$ARMS_DIR" status --short || true
        else
            echo "git_head:  no git"
        fi
    else
        echo "git_head:  no git binary"
    fi
    echo "fast_mem_sizes: ${FAST_MEM_SIZES}"
    echo "num_sizes:      ${#SIZE_ARRAY[@]}"
    echo "iterations:     ${ITERATIONS}"
    echo "suite:         ${SUITE}"
    echo "workload:      ${WORKLOAD}"
    echo "target_exe:    ${TARGET_EXE}"
    echo "lib_arms_path: ${LIB_ARMS_PATH}"
    echo "working_dir:   ${WORKING_DIR}"
    if command -v sha256sum >/dev/null 2>&1; then
        echo "libarms_sha256: $(sha256sum "$LIB_ARMS_PATH" | awk '{print $1}')"
    fi
} > "$META"

# =============================================================================
# STEP 5: Final summary
# =============================================================================

echo ""
echo "============================================================"
echo "[eval] Done."
echo "  CSV:      ${CSV}"
echo "  Metadata: ${META}"
echo ""
echo "[eval] Per-size/config summary (mean +/- std of Average Time across iterations):"
python3 - <<PY
import csv, statistics
from collections import defaultdict
rows = []
with open("${CSV}") as f:
    for r in csv.DictReader(f):
        rows.append(r)
by_sz_cfg = defaultdict(list)
for r in rows:
    try:
        by_sz_cfg[(r["fast_mem"], r["config"])].append(float(r["avg_time_seconds"]))
    except (ValueError, KeyError):
        pass
prev_sz = None
for (sz, cfg), vals in sorted(by_sz_cfg.items(), key=lambda x: (float(x[0][0].rstrip("GgMm") if x[0][0][-1] in "GgMm" else x[0][0]), x[0][1])):
    if sz != prev_sz:
        print(f"  --- {sz} ---")
        prev_sz = sz
    if not vals:
        print(f"    {cfg:15s} N=0")
        continue
    mean = statistics.mean(vals)
    std = statistics.stdev(vals) if len(vals) > 1 else 0.0
    print(f"    {cfg:15s} N={len(vals):4d}  mean={mean:.5f}s  std={std:.5f}s")
PY

echo ""
echo "[eval] To plot:"
echo "  python3 ${WORKING_DIR}/workloads/scripts/plot_duration_pred_comparison.py \"${RUN_DIR}\""
echo "============================================================"
