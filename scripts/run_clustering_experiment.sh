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
# Two experiment modes live side-by-side:
#   Legacy:  one BIRCH model per workload, built from scratch.
#   Shared:  one BIRCH model per phase per iteration, loaded/updated/saved as
#            each workload in a shuffled order runs through it.
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

SHUFFLE_ITERATIONS="${SHUFFLE_ITERATIONS:-3}"
SHUFFLE_SEED="${SHUFFLE_SEED:-$(date +%s)}"

# =============================================================================
# WORKLOAD REGISTRY
# =============================================================================
# Format: "suite:workload:target_exe"
# Comment out entries to skip workloads.

WORKLOADS=(
    "micro_interference:micro_interference:micro_interference"
    #"gapbs:bc:bc"
    #"gapbs:bfs:bfs"
    #"gapbs:pr:pr"
    #"gapbs:pr_spmv:pr_spmv"
    #"gapbs:cc:cc"
    #"gapbs:cc_sv:cc_sv"
    #"gapbs:sssp:sssp"
    #"gapbs:tc:tc"
    #"liblinear:liblinear:train"
    #"merci:merci:eval_baseline"
    #"xsbench:xsbench:XSBench"
    #"cloverleaf:cloverleaf:clover_leaf"
    #"silo:silo:dbtest"
)

# =============================================================================
# COMMON ENVIRONMENT
# =============================================================================

export REGENT_FAST_MEMORY="$FAST_MEM"
export ARMS_POLICY="$ARMS_POLICY"
export REGENT_VISUALIZATION=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/../run.sh"
CROSS_PLOT_SCRIPT="${ARMS_DIR}/scripts/plot_centroids_cross.py"

# =============================================================================
# FUNCTIONS
# =============================================================================

build_arms() {
    local coldness_flag="$1"
    local dest_path="$2"

    if [[ -f "$dest_path" ]]; then
        echo "=========================================="
        echo "ARMS already built: ${dest_path} (skipping rebuild)"
        echo "=========================================="
        return
    fi

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

run_build_birch_shared() {
    local suite="$1"
    local workload="$2"
    local target_exe="$3"
    local output_dir="$4"
    local shared_model="$5"

    echo "=========================================="
    echo "SHARED BIRCH: ${suite}/${workload}"
    echo "  Output dir:    ${output_dir}"
    echo "  Shared model:  ${shared_model}"
    if [[ -f "$shared_model" ]]; then
        echo "  Mode:          load + update + save (model exists, size=$(stat -c%s "$shared_model"))"
    else
        echo "  Mode:          fresh build (no existing model)"
    fi
    echo "=========================================="

    # Updates must happen: RO must stay unset.
    unset REGENT_RO_BIRCH

    if [[ -f "$shared_model" ]]; then
        export BIRCH_INPUT="$shared_model"
    else
        unset BIRCH_INPUT
    fi

    export BIRCH_OUTPUT="$shared_model"
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

# Deterministic shuffle of WORKLOADS seeded from $1.
# Emits one entry per line, portable across GNU/BSD shuf availability.
shuffle_workloads() {
    local seed="$1"
    local i
    for i in "${!WORKLOADS[@]}"; do
        printf '%s\n' "${WORKLOADS[$i]}"
    done | awk -v s="$seed" '
        BEGIN { srand(s) }
        { lines[NR] = $0 }
        END {
            n = NR
            for (i = n; i > 1; i--) {
                j = int(rand() * i) + 1
                tmp = lines[i]; lines[i] = lines[j]; lines[j] = tmp
            }
            for (i = 1; i <= n; i++) print lines[i]
        }
    '
}

plot_cross_results() {
    local results_dir="$1"

    if ! command -v conda >/dev/null 2>&1; then
        echo "WARNING: conda not on PATH; skipping cross-workload plotting for ${results_dir}."
        echo "         To plot manually:"
        echo "           conda activate dataVis"
        echo "           python3 ${CROSS_PLOT_SCRIPT} ${results_dir}"
        return
    fi

    echo "=============================================="
    echo "Generating cross-workload centroid plots for ${results_dir} ..."
    echo "=============================================="
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate dataVis
    python3 "$CROSS_PLOT_SCRIPT" "$results_dir"
    conda deactivate
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
        run_ro_birch "$suite" "$workload" "$target_exe" "$ro_dir" "$birch_model"
    done
}

# Runs one shared-model iteration: picks a shuffled workload order (same for
# both phases within the iteration) and layers each workload into the shared
# tree. The tagged .so per phase is assumed to already exist.
run_shared_iteration() {
    local iter_index="$1"
    local iter_seed="$2"

    local iter_base="${OUTPUT_BASE}/shared_iter${iter_index}"
    mkdir -p "$iter_base"

    # Compute shuffled order once; reuse across phases so the NN-prefix labels
    # line up between hot/ and hot_cold/ scatter plots within an iteration.
    local shuffled
    shuffled="$(shuffle_workloads "$iter_seed")"

    {
        echo "seed=${iter_seed}"
        echo "iteration=${iter_index}"
        local pos=0
        while IFS= read -r entry; do
            pos=$((pos + 1))
            printf '%02d %s\n' "$pos" "$entry"
        done <<< "$shuffled"
    } > "${iter_base}/order.txt"

    echo "=============================================="
    echo "Shared iteration ${iter_index} (seed=${iter_seed})"
    echo "  Order file: ${iter_base}/order.txt"
    echo "=============================================="

    local phase
    for phase in hot hot_cold; do
        local lib_tagged="${OUTPUT_BASE}/libarms_kernel_${phase}.so"
        if [[ ! -f "$lib_tagged" ]]; then
            echo "ERROR: expected tagged arms lib missing: ${lib_tagged}" >&2
            exit 1
        fi

        export LIB_ARMS_PATH="$lib_tagged"
        export HEMEMPOL="$lib_tagged"

        local phase_root="${iter_base}/${phase}"
        local model_dir="${phase_root}/birch_models"
        local shared_model="${model_dir}/shared_union.bin"
        mkdir -p "$phase_root" "$model_dir"

        echo "----------------------------------------------"
        echo "  Phase: ${phase}"
        echo "  Shared model: ${shared_model}"
        echo "----------------------------------------------"

        local pos=0
        while IFS= read -r entry; do
            pos=$((pos + 1))
            IFS=':' read -r suite workload target_exe <<< "$entry"
            local dir_prefix
            dir_prefix=$(printf '%02d' "$pos")
            local build_dir="${phase_root}/${dir_prefix}_${suite}_${workload}_build"
            run_build_birch_shared "$suite" "$workload" "$target_exe" \
                "$build_dir" "$shared_model"
        done <<< "$shuffled"
    done
}

run_phase_shared() {
    echo "=============================================="
    echo "Shared-model experiment"
    echo "  Iterations:     ${SHUFFLE_ITERATIONS}"
    echo "  Base seed:      ${SHUFFLE_SEED}"
    echo "=============================================="

    # Build (or reuse) both tagged arms libs up front so all iterations share
    # the same binaries.
    build_arms 0 "${OUTPUT_BASE}/libarms_kernel_hot.so"
    build_arms 1 "${OUTPUT_BASE}/libarms_kernel_hot_cold.so"

    local i
    for ((i = 1; i <= SHUFFLE_ITERATIONS; i++)); do
        local iter_seed=$((SHUFFLE_SEED + i))
        run_shared_iteration "$i" "$iter_seed"
        plot_cross_results "${OUTPUT_BASE}/shared_iter${i}"
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

# --- Legacy per-workload experiment (comment out to skip) ---
#run_phase "hot"      0
run_phase "hot_cold" 1
plot_cross_results "$OUTPUT_BASE"

# --- Shared-model experiment (comment out to skip) ---
#run_phase_shared

echo "=============================================="
echo "All clustering experiments completed!"
echo "  Output base: ${OUTPUT_BASE}"
echo "=============================================="
