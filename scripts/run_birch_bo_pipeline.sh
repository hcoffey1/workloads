#!/bin/bash
# =============================================================================
# Full BIRCH Clustering + BO Tuning Pipeline
# =============================================================================
# Step 1: Run clustering experiment (produces BIRCH model)
# Step 2: Generate BO configs from BIRCH model
# Step 3: Run parallel BO tuning
# Step 4: Run individual cluster BO tuning (commentable)
# Step 5: Package results into timestamped directory
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

FAST_MEM="${FAST_MEM:-8G}"
FAST_MEM_MB="${FAST_MEM_MB:-8192}"
BO_ITERATIONS="${BO_ITERATIONS:-30}"
N_INITIAL_POINTS="${N_INITIAL_POINTS:-8}"
ITERATIONS_PER_TRIAL="${ITERATIONS_PER_TRIAL:-1}"
BACKUP_FAST_MEMORY="${BACKUP_FAST_MEMORY:-512M}"

WORKING_DIR="${WORKING_DIR:-$HOME/working}"
ARMS_DIR="${ARMS_DIR:-${WORKING_DIR}/arms}"
BO_ENGINE_DIR="${BO_ENGINE_DIR:-${WORKING_DIR}/bo_engine}"
WORKLOADS_DIR="${WORKLOADS_DIR:-${WORKING_DIR}/workloads}"
LIB_ARMS_PATH="${LIB_ARMS_PATH:-${ARMS_DIR}/libarms_kernel.so}"
BIRCH_INFO_PATH="${BIRCH_INFO_PATH:-${ARMS_DIR}/birch_info}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="${RESULT_DIR:-results_birch_bo_${TIMESTAMP}}"

# Workloads to tune (format: "suite:workload:target_exe")
WORKLOADS=(
    "gapbs:bc:bc"
    # "gapbs:bfs:bfs"
    # "gapbs:pr:pr"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# FUNCTIONS
# =============================================================================

step_clustering() {
    local suite="$1"
    local workload="$2"
    local target_exe="$3"

    echo "=========================================="
    echo "STEP 1: Clustering experiment for ${suite}/${workload}"
    echo "=========================================="

    local clustering_output="${RESULT_DIR}/clustering"
    export OUTPUT_BASE="$clustering_output"
    export FAST_MEM="$FAST_MEM"
    export LIB_ARMS_PATH="$LIB_ARMS_PATH"

    # Run just this workload through clustering
    local birch_model="${clustering_output}/birch_models/${suite}_${workload}_birch.bin"
    local build_dir="${clustering_output}/${suite}_${workload}_build"
    local ro_dir="${clustering_output}/${suite}_${workload}_ro"

    mkdir -p "${clustering_output}/birch_models"

    # Source clustering experiment functions
    export HEMEMPOL="$LIB_ARMS_PATH"
    export REGENT_FAST_MEMORY="$FAST_MEM"
    export ARMS_POLICY="${ARMS_POLICY:-ARMS}"
    export REGENT_VISUALIZATION=1

    local run_sh="${WORKLOADS_DIR}/run.sh"

    # Build BIRCH model
    echo "  Building BIRCH model..."
    unset REGENT_RO_BIRCH
    unset BIRCH_INPUT
    export BIRCH_OUTPUT="$birch_model"
    export REGENT_TARGET_EXE="$target_exe"
    "$run_sh" -b "$suite" -w "$workload" -o "$build_dir" -r 1 --use-cgroup

    # RO run
    echo "  Running RO BIRCH..."
    export REGENT_RO_BIRCH=1
    export BIRCH_INPUT="$birch_model"
    export BIRCH_OUTPUT="$birch_model"
    "$run_sh" -b "$suite" -w "$workload" -o "$ro_dir" -r 1 --use-cgroup

    # Copy BIRCH model to models dir
    mkdir -p "${RESULT_DIR}/birch_models"
    cp "$birch_model" "${RESULT_DIR}/birch_models/"
}

step_generate_configs() {
    local suite="$1"
    local workload="$2"
    local target_exe="$3"

    echo "=========================================="
    echo "STEP 2: Generate BO configs for ${suite}/${workload}"
    echo "=========================================="

    local birch_model="${RESULT_DIR}/birch_models/${suite}_${workload}_birch.bin"
    local config_dir="${RESULT_DIR}/configs/${suite}_${workload}"

    python3 "${BO_ENGINE_DIR}/generate_cluster_bo_configs.py" \
        --birch-model "$birch_model" \
        --suite "$suite" \
        --workload "$workload" \
        --target-exe "$target_exe" \
        --fast-mem-mb "$FAST_MEM_MB" \
        --output-dir "$config_dir" \
        --birch-info-path "$BIRCH_INFO_PATH" \
        --lib-arms-kernel-path "$LIB_ARMS_PATH" \
        --workloads-dir "$WORKLOADS_DIR" \
        --results-base-dir "${RESULT_DIR}/${suite}_${workload}" \
        --bo-iterations "$BO_ITERATIONS" \
        --n-initial-points "$N_INITIAL_POINTS" \
        --backup-fast-memory "$BACKUP_FAST_MEMORY"
}

step_parallel_tuning() {
    local suite="$1"
    local workload="$2"

    echo "=========================================="
    echo "STEP 3: Parallel BO tuning for ${suite}/${workload}"
    echo "=========================================="

    local config="${RESULT_DIR}/configs/${suite}_${workload}/bo_cluster_parallel.yaml"

    python3 "${BO_ENGINE_DIR}/run_cluster_bo.py" \
        --config "$config" \
        --iterations-per-trial "$ITERATIONS_PER_TRIAL"
}

step_individual_tuning() {
    local suite="$1"
    local workload="$2"
    local num_clusters="$3"

    echo "=========================================="
    echo "STEP 4: Individual BO tuning for ${suite}/${workload}"
    echo "=========================================="

    for ((c=0; c<num_clusters; c++)); do
        local config="${RESULT_DIR}/configs/${suite}_${workload}/bo_cluster_individual_${c}.yaml"

        echo "  Tuning cluster ${c}..."
        python3 "${BO_ENGINE_DIR}/run_cluster_bo.py" \
            --config "$config" \
            --iterations-per-trial "$ITERATIONS_PER_TRIAL"
    done
}

get_num_clusters() {
    local birch_model="$1"
    "$BIRCH_INFO_PATH" "$birch_model" | python3 -c "import sys, json; print(json.load(sys.stdin)['num_clusters'])"
}

# =============================================================================
# MAIN
# =============================================================================

mkdir -p "$RESULT_DIR"

echo "=============================================="
echo "BIRCH Clustering + BO Tuning Pipeline"
echo "  Result dir:   ${RESULT_DIR}"
echo "  Fast memory:  ${FAST_MEM} (${FAST_MEM_MB} MB)"
echo "  BO iters:     ${BO_ITERATIONS}"
echo "  Workloads:    ${#WORKLOADS[@]}"
echo "=============================================="

for entry in "${WORKLOADS[@]}"; do
    IFS=':' read -r suite workload target_exe <<< "$entry"

    # Step 1: Clustering
    step_clustering "$suite" "$workload" "$target_exe"

    # Step 2: Generate configs
    step_generate_configs "$suite" "$workload" "$target_exe"

    # Get cluster count
    birch_model="${RESULT_DIR}/birch_models/${suite}_${workload}_birch.bin"
    num_clusters=$(get_num_clusters "$birch_model")

    # Step 3: Parallel tuning
    step_parallel_tuning "$suite" "$workload"

    # Step 4: Individual tuning (comment out to skip)
    step_individual_tuning "$suite" "$workload" "$num_clusters"
done

# Step 5: Summary
echo "=============================================="
echo "Pipeline complete!"
echo "Results in: ${RESULT_DIR}"
echo "  clustering/                        — raw clustering experiment output"
echo "  birch_models/                      — BIRCH model binaries"
echo "  configs/                           — generated BO configs"
echo "  <suite>_<workload>/parallel_tuning/    — parallel BO results"
echo "  <suite>_<workload>/individual_tuning/  — per-cluster BO results"
echo "=============================================="
