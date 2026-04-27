#!/bin/bash
# =============================================================================
# ARMS Cluster-Aware vs Baseline Evaluation Harness
# =============================================================================
# Builds libarms_kernel.so with the requested cluster-aware flags and runs
# gapbs bc twice through workloads/run.sh:
#
#   1) BASELINE      — REGENT_NO_CLUSTERING=1, baseline arms_* policy
#   2) CLUSTER_AWARE — clustering ON, REGENT_ARMS_VARIANT=cluster_aware
#
# Supports sweeping across multiple fast-memory tier sizes via FAST_MEM_SIZES.
# Collects per-trial times from stdout logs and writes a long-format CSV
# suitable for plot_arms_cluster_aware_comparison.py.
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

SUITE="${SUITE:-liblinear}"
WORKLOAD="${WORKLOAD:-liblinear}"
TARGET_EXE="${TARGET_EXE:-train}"
FAST_MEM="${FAST_MEM:-8G}"
ITERATIONS="${ITERATIONS:-1}"

RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-${WORKING_DIR}/workloads/results_arms_ca_eval}"

# Multi-size sweep: space-separated list of fast-memory sizes (e.g. "0.5G 1G 2G").
# Defaults to 0.5G–8G in 0.5G increments. Set to a single value for a quick run.
# Falls back to FAST_MEM if unset.
#FAST_MEM_SIZES="${FAST_MEM_SIZES:-0.5G 1G 1.5G 2G 2.5G 3G 3.5G 4G 4.5G 5G 5.5G 6G 6.5G 7G 7.5G 8G}"
#FAST_MEM_SIZES="${FAST_MEM_SIZES:-0.1G 0.25G 0.5G 1G 1.25G 1.5G 1.75G 2G 2.5G 3G 3.5G 4G 8G 16G}"
FAST_MEM_SIZES=""

# Full cluster-aware flag set — override for rule-isolation studies, e.g.:
#   ARMS_CA_FLAGS="ENABLE_ARMS_CLUSTER_AWARE=1 ARMS_CA_EWMA_WINDOWS=1 \
#                  ARMS_CA_HOT_AGE_GATE=0 ARMS_CA_CB_MULTIPLIER=0" \
#   ./run_arms_cluster_aware_eval.sh
ARMS_CA_FLAGS="${ARMS_CA_FLAGS:-ENABLE_ARMS_CLUSTER_AWARE=1 ARMS_CA_HOT_AGE_GATE=1 ARMS_CA_EWMA_WINDOWS=1 ARMS_CA_CB_MULTIPLIER=1}"

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
# STEP 1: Build libarms_kernel.so with the requested flags
# =============================================================================

echo "============================================================"
echo "[eval] ARMS cluster-aware vs baseline (multi-size sweep)"
echo "  Workload:   ${SUITE}/${WORKLOAD}"
echo "  Sizes:      ${FAST_MEM_SIZES}  (${#SIZE_ARRAY[@]} sizes)"
echo "  Iterations: ${ITERATIONS}"
echo "  Flags:      ${ARMS_CA_FLAGS}"
echo "  Results:    ${RESULTS_BASE_DIR}"
echo "============================================================"

echo "[eval] Building libarms_kernel.so with: ${ARMS_CA_FLAGS}"
make -C "$ARMS_DIR" clean
# shellcheck disable=SC2086
make -C "$ARMS_DIR" ${ARMS_CA_FLAGS} -j"$(nproc)"
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
    mkdir -p "${RUN_DIR}/${sz}/baseline" "${RUN_DIR}/${sz}/cluster_aware"
done

# Shared env for all runs
export HEMEMPOL="$LIB_ARMS_PATH"
export REGENT_TARGET_EXE="$TARGET_EXE"
export REGENT_VISUALIZATION=0
unset REGENT_STATIC_CONFIG

# --- Loop over sizes ---------------------------------------------------------
for sz_idx in "${!SIZE_ARRAY[@]}"; do
    sz="${SIZE_ARRAY[$sz_idx]}"
    echo ""
    echo "============================================================"
    echo "[eval] Size ${sz}  ($((sz_idx + 1))/${#SIZE_ARRAY[@]})"
    echo "============================================================"

    export REGENT_FAST_MEMORY="$sz"

    # --- Run 1: BASELINE (control) ------------------------------------------
    echo ""
    echo "[eval] === ${sz} — Run 1: BASELINE (clustering=OFF) ==="
    export REGENT_NO_CLUSTERING=1
    unset REGENT_ARMS_VARIANT
    "$RUN_SH" -b "$SUITE" -w "$WORKLOAD" \
        -o "${RUN_DIR}/${sz}/baseline" \
        -r "$ITERATIONS" \
        --use-cgroup

    # --- Run 2: CLUSTER-AWARE -----------------------------------------------
    echo ""
    echo "[eval] === ${sz} — Run 2: CLUSTER-AWARE (clustering=ON) ==="
    unset REGENT_NO_CLUSTERING
    export REGENT_ARMS_VARIANT=cluster_aware
    "$RUN_SH" -b "$SUITE" -w "$WORKLOAD" \
        -o "${RUN_DIR}/${sz}/cluster_aware" \
        -r "$ITERATIONS" \
        --use-cgroup
done

# =============================================================================
# STEP 3: Extract trial times -> long-format CSV
# =============================================================================

CSV="${RUN_DIR}/iteration_times.csv"
echo "fast_mem,fast_mem_gb,config,iteration,trial,trial_time_seconds" > "$CSV"

extract_trials() {
    local config="$1"
    local dir="$2"
    local fast_mem_label="$3"
    local fast_mem_gb="$4"
    local any_trials=0

    # gapbs iter files: <suite>_<workload>_<policy>_<dram>_iter<N>_stdout.txt
    for stdout_file in "$dir"/*_iter*_stdout.txt; do
        [[ -f "$stdout_file" ]] || continue

        # Parse iteration number from filename (e.g., ..._iter3_stdout.txt -> 3)
        local base
        base=$(basename "$stdout_file")
        local iter
        iter=$(echo "$base" | sed -n 's/.*_iter\([0-9]\+\)_stdout\.txt$/\1/p')
        [[ -z "$iter" ]] && iter=0

        # Extract Trial Time lines.  gapbs prints `Trial Time:   X.XXXXX`.
        local trial_idx=0
        local matched=0
        while IFS= read -r line; do
            # Match leading whitespace variation of Trial Time
            if [[ "$line" =~ ^[[:space:]]*Trial[[:space:]]+Time:[[:space:]]+([0-9]+\.[0-9]+) ]]; then
                echo "${fast_mem_label},${fast_mem_gb},${config},${iter},${trial_idx},${BASH_REMATCH[1]}" >> "$CSV"
                trial_idx=$((trial_idx + 1))
                matched=1
            fi
        done < "$stdout_file"

        if [[ $matched -eq 1 ]]; then
            any_trials=1
        else
            # Fallback: parse wall-clock `real 0mX.XXs` from the time file.
            local time_file="${stdout_file%_stdout.txt}_time.txt"
            if [[ -f "$time_file" ]]; then
                local real_line
                real_line=$(grep -E '^real' "$time_file" || true)
                if [[ -n "$real_line" ]]; then
                    # e.g. "real 0m12.345s" -> 12.345
                    local seconds
                    seconds=$(echo "$real_line" | sed -n 's/^real[[:space:]]*\([0-9]\+\)m\([0-9.]\+\)s/\1 \2/p' \
                              | awk '{printf "%.5f", $1*60 + $2}')
                    if [[ -n "$seconds" ]]; then
                        echo "${fast_mem_label},${fast_mem_gb},${config},${iter},-1,${seconds}" >> "$CSV"
                        echo "[eval] WARNING: no Trial Time in ${stdout_file}; fell back to real=${seconds}s" >&2
                    fi
                fi
            fi
        fi
    done

    if [[ $any_trials -eq 0 ]]; then
        echo "[eval] WARNING: ${config} (${fast_mem_label}) has no Trial Time rows; only fallback rows will be present (if any)" >&2
    fi
}

for sz in "${SIZE_ARRAY[@]}"; do
    gb=$(size_to_gb "$sz")
    extract_trials "baseline"      "${RUN_DIR}/${sz}/baseline"      "$sz" "$gb"
    extract_trials "cluster_aware" "${RUN_DIR}/${sz}/cluster_aware"  "$sz" "$gb"
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
    echo "arms_ca_flags:  ${ARMS_CA_FLAGS}"
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
echo "[eval] Per-size/config summary (mean +/- std across all trials):"
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
        by_sz_cfg[(r["fast_mem"], r["config"])].append(float(r["trial_time_seconds"]))
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
echo "  python3 ${WORKING_DIR}/workloads/scripts/plot_arms_cluster_aware_comparison.py \"${RUN_DIR}\""
echo "============================================================"
