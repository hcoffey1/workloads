#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# msCRUSH paths
MSCRUSH_DIR="$CUR_PATH/msCRUSH"
MSCRUSH_DATA_DIR="$MSCRUSH_DIR/mgf"
MSCRUSH_SCALE_ROOT="$MSCRUSH_DIR/mgf_scaled"
MSCRUSH_BIN="$MSCRUSH_DIR/bin/mscrush_on_general_charge"
MSCRUSH_CONSENSUS_BIN="$MSCRUSH_DIR/bin/generate_consensus_spectrum_for_mscrush"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Create a scaled dataset by duplicating the bundled MGF files with unique titles
prepare_mscrush_dataset() {
    local size="$1"
    local copies="$2"

    if [[ -z "$copies" || "$copies" -lt 1 ]]; then
        echo "ERROR: prepare_mscrush_dataset requires a positive copy count" >&2
        return 1
    fi

    local target_dir="$MSCRUSH_SCALE_ROOT/${size}_${copies}x"
    local -a base_files=("$MSCRUSH_DATA_DIR"/D01.part.*.mgf)

    if [[ ! -d "$MSCRUSH_DATA_DIR" || ${#base_files[@]} -eq 0 ]]; then
        echo "ERROR: No base MGF files found under $MSCRUSH_DATA_DIR" >&2
        return 1
    fi

    local expected_total=$(( ${#base_files[@]} * copies ))

    if [[ -d "$target_dir" ]]; then
        local existing_total
        existing_total=$(find "$target_dir" -maxdepth 1 -name '*.mgf' | wc -l | tr -d ' ')
        if [[ "$existing_total" -eq "$expected_total" ]]; then
            echo "Reusing existing scaled dataset: $target_dir ($existing_total files)" >&2
            echo "$target_dir"
            return 0
        fi
        echo "Rebuilding scaled dataset for $size (found $existing_total, expected $expected_total)" >&2
        rm -rf "$target_dir"
    fi

    mkdir -p "$target_dir"

    echo "Generating scaled dataset ($copies copies of ${#base_files[@]} base files)" >&2
    local copy_index
    local default_jobs
    if command -v nproc >/dev/null 2>&1; then
        default_jobs=$(nproc)
    else
        default_jobs=1
    fi
    local max_jobs="${MSCRUSH_SCALE_JOBS:-$default_jobs}"
    if ! [[ "$max_jobs" =~ ^[0-9]+$ ]] || (( max_jobs < 1 )); then
        max_jobs=1
    fi
    local -a active_pids=()

    for original in "${base_files[@]}"; do
        local base_name
        base_name=$(basename "$original" .mgf)
        for ((copy_index = 0; copy_index < copies; copy_index++)); do
            local suffix
            suffix=$(printf '%03d' "$copy_index")
            local dest_file="$target_dir/${base_name}_copy${suffix}.mgf"
            if [[ -f "$dest_file" ]]; then
                continue
            fi
            #printf '  -> %-40s' "${base_name}_copy${suffix}.mgf" >&2
            (
                cp "$original" "$dest_file"
                LC_ALL=C sed -i "s/^TITLE=/TITLE=COPY${suffix}_/" "$dest_file"
                #echo " done" >&2
            ) &
            active_pids+=($!)
            if (( ${#active_pids[@]} >= max_jobs )); then
                if ! wait "${active_pids[0]}"; then
                    echo "Scaling copy job failed" >&2
                    return 1
                fi
                active_pids=(${active_pids[@]:1})
            fi
        done
    done

    local pid
    for pid in "${active_pids[@]}"; do
        if ! wait "$pid"; then
            echo "Scaling copy job failed" >&2
            return 1
        fi
    done

    local generated_total
    generated_total=$(find "$target_dir" -maxdepth 1 -name '*.mgf' | wc -l | tr -d ' ')
    echo "Created $generated_total MGF files in $target_dir" >&2
    du -sh "$target_dir" >&2

    echo "$target_dir"
}

# Write a small manifest alongside cluster outputs so phase 2 knows what to load
write_mscrush_manifest() {
    local manifest_path="$1"
    local dataset_dir="$2"
    local input_pattern="$3"
    local delimiter="$4"
    local size="$5"

    cat > "$manifest_path" <<EOF_MANIFEST
MSCRUSH_MANIFEST_SIZE="$size"
MSCRUSH_MANIFEST_DATASET_DIR="$dataset_dir"
MSCRUSH_MANIFEST_INPUT_PATTERN="$input_pattern"
MSCRUSH_MANIFEST_DELIMITER="$delimiter"
EOF_MANIFEST
}

# Load manifest produced by phase 1
load_mscrush_manifest() {
    local manifest_path="$1"
    if [[ ! -f "$manifest_path" ]]; then
        echo "ERROR: Manifest not found at $manifest_path" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$manifest_path"
}

# -----------------------------------------------------------------------------
# Workload hooks
# -----------------------------------------------------------------------------

config_mscrush(){
    local config_file="$1"
    local workload="$2"

    MSCRUSH_PHASE="${MSCRUSH_PHASE:-cluster}"   # cluster | consensus
    MSCRUSH_SIZE="${MSCRUSH_SIZE:-medium}"
    MSCRUSH_THREADS="${MSCRUSH_THREADS:-20}"
    MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
    MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-100}"
    MSCRUSH_MIN_SIMILARITY="${MSCRUSH_MIN_SIMILARITY:-0.65}"
    MSCRUSH_MIN_MZ="${MSCRUSH_MIN_MZ:-200}"
    MSCRUSH_MAX_MZ="${MSCRUSH_MAX_MZ:-2000}"
    MSCRUSH_DELIMITER="${MSCRUSH_DELIMITER:-|}"

    MSCRUSH_CONSENSUS_DECIMAL="${MSCRUSH_CONSENSUS_DECIMAL:-7}"
    MSCRUSH_CONSENSUS_TITLE="${MSCRUSH_CONSENSUS_TITLE:-CONSENSUS}"
    MSCRUSH_CONSENSUS_PREFIX="${MSCRUSH_CONSENSUS_PREFIX:-consensus}"

    case "$MSCRUSH_PHASE" in
        "cluster")
            local copy_count
            case "$MSCRUSH_SIZE" in
                "small")
                    copy_count=5   # ~1.8 GB
                    ;;
                "medium")
                    copy_count=27  # ~10 GB
                    ;;
                "large")
                    copy_count=54  # ~20 GB
                    ;;
                "xlarge")
                    copy_count=108 # ~40 GB
                    ;;
                *)
                    echo "ERROR: Unknown MSCRUSH_SIZE '$MSCRUSH_SIZE'" >&2
                    echo "Valid options: small, medium, large, xlarge" >&2
                    return 1
                    ;;
            esac

            echo "Preparing msCRUSH cluster run (size=$MSCRUSH_SIZE, copies=$copy_count)"
            local dataset_dir
            dataset_dir=$(prepare_mscrush_dataset "$MSCRUSH_SIZE" "$copy_count") || return 1
            MSCRUSH_DATASET_DIR="$dataset_dir"
            MSCRUSH_INPUT_FILES="$dataset_dir/*.mgf"
            ;;
        "consensus")
            MSCRUSH_CLUSTER_PREFIX="${MSCRUSH_CLUSTER_PREFIX:-}"
            if [[ -z "$MSCRUSH_CLUSTER_PREFIX" ]]; then
                echo "ERROR: Set MSCRUSH_CLUSTER_PREFIX to the phase-1 cluster prefix" >&2
                return 1
            fi

            local manifest_path="${MSCRUSH_CLUSTER_PREFIX}_manifest.sh"
            if load_mscrush_manifest "$manifest_path"; then
                MSCRUSH_SIZE="${MSCRUSH_SIZE:-${MSCRUSH_MANIFEST_SIZE:-unknown}}"
                MSCRUSH_INPUT_FILES="${MSCRUSH_INPUT_FILES:-${MSCRUSH_MANIFEST_INPUT_PATTERN}}"
                MSCRUSH_DELIMITER="${MSCRUSH_DELIMITER:-${MSCRUSH_MANIFEST_DELIMITER:-|}}"
                if [[ -z "$MSCRUSH_INPUT_FILES" ]]; then
                    echo "ERROR: Manifest did not provide input pattern" >&2
                    return 1
                fi
            else
                echo "WARNING: Manifest missing, falling back to manual configuration" >&2
                if [[ -z "$MSCRUSH_INPUT_FILES" ]]; then
                    echo "ERROR: Set MSCRUSH_INPUT_FILES to the MGF pattern for consensus" >&2
                    return 1
                fi
            fi
            ;;
        *)
            echo "ERROR: Unknown MSCRUSH_PHASE '$MSCRUSH_PHASE'" >&2
            return 1
            ;;
    esac

    export MSCRUSH_PHASE MSCRUSH_SIZE MSCRUSH_THREADS MSCRUSH_HASH_FUNCS
    export MSCRUSH_ITERATIONS MSCRUSH_MIN_SIMILARITY MSCRUSH_MIN_MZ MSCRUSH_MAX_MZ
    export MSCRUSH_DELIMITER MSCRUSH_INPUT_FILES MSCRUSH_DATASET_DIR
    export MSCRUSH_CONSENSUS_DECIMAL MSCRUSH_CONSENSUS_TITLE MSCRUSH_CONSENSUS_PREFIX
    export MSCRUSH_CLUSTER_PREFIX

    echo "=== msCRUSH configuration ==="
    echo "Phase:          $MSCRUSH_PHASE"
    echo "Size:           $MSCRUSH_SIZE"
    echo "Threads:        $MSCRUSH_THREADS"
    echo "Hash funcs:     $MSCRUSH_HASH_FUNCS"
    echo "Iterations:     $MSCRUSH_ITERATIONS"
    echo "Similarity:     $MSCRUSH_MIN_SIMILARITY"
    echo "m/z range:      $MSCRUSH_MIN_MZ - $MSCRUSH_MAX_MZ"
    echo "Delimiter:      $MSCRUSH_DELIMITER"
    if [[ "$MSCRUSH_PHASE" == "cluster" ]]; then
        echo "Dataset dir:    $MSCRUSH_DATASET_DIR"
        echo "Input pattern:  $MSCRUSH_INPUT_FILES"
    else
        echo "Cluster prefix: $MSCRUSH_CLUSTER_PREFIX"
        echo "MGF pattern:    $MSCRUSH_INPUT_FILES"
    fi
    echo "============================="
}

build_mscrush(){
    local workload=$1

    echo "Building msCRUSH tooling..."
    pushd "$MSCRUSH_DIR" > /dev/null

    pushd src/app > /dev/null
    echo "Compiling mscrush_on_general_charge..."
    bash compile_mscrush_on_general_charge.sh
    echo "Compiling generate_consensus_spectrum_for_mscrush..."
    bash compile_generate_consensus_spectrum_for_mscrush.sh
    popd > /dev/null

    mkdir -p "$MSCRUSH_DIR/bin"
    mv -f "$MSCRUSH_DIR"/src/app/mscrush_on_general_charge "$MSCRUSH_BIN"
    mv -f "$MSCRUSH_DIR"/src/app/generate_consensus_spectrum_for_mscrush "$MSCRUSH_CONSENSUS_BIN"

    if [[ ! -x "$MSCRUSH_BIN" || ! -x "$MSCRUSH_CONSENSUS_BIN" ]]; then
        echo "ERROR: Failed to build msCRUSH binaries" >&2
        popd > /dev/null
        exit 1
    fi

    echo "msCRUSH binaries ready"
    popd > /dev/null
}

run_mscrush(){
    local workload=$1
    generate_workload_filenames "$workload"

    case "$MSCRUSH_PHASE" in
        "cluster")
            local cluster_dir="$OUTPUT_DIR/clusters"
            mkdir -p "$cluster_dir"

            local cluster_prefix="$cluster_dir/${SUITE}_${WORKLOAD}_${MSCRUSH_SIZE}"
            if [[ -n "$CURRENT_ITERATION" ]]; then
                cluster_prefix+="_iter${CURRENT_ITERATION}"
            fi
            cluster_prefix+="_clusters"

            local manifest_path="${cluster_prefix}_manifest.sh"
            write_mscrush_manifest "$manifest_path" "$MSCRUSH_DATASET_DIR" "$MSCRUSH_INPUT_FILES" "$MSCRUSH_DELIMITER" "$MSCRUSH_SIZE"

            local binary_args="-f $MSCRUSH_INPUT_FILES"
            binary_args+=" -t $MSCRUSH_THREADS"
            binary_args+=" -n $MSCRUSH_HASH_FUNCS"
            binary_args+=" -i $MSCRUSH_ITERATIONS"
            binary_args+=" -s $MSCRUSH_MIN_SIMILARITY"
            binary_args+=" -l $MSCRUSH_MIN_MZ"
            binary_args+=" -r $MSCRUSH_MAX_MZ"
            binary_args+=" -d '$MSCRUSH_DELIMITER'"
            binary_args+=" -c \"$cluster_prefix\""

            echo "Command preview: $MSCRUSH_BIN $binary_args"
            create_workload_wrapper "$WRAPPER" "$PIDFILE" "$MSCRUSH_BIN" "$binary_args" ""

            echo "Launching msCRUSH clustering..."
            echo "Cluster output prefix: $cluster_prefix"
            echo "Manifest: $manifest_path"
            echo "To run consensus later: MSCRUSH_PHASE=consensus MSCRUSH_CLUSTER_PREFIX=$cluster_prefix ./run.sh ..."

            run_workload_standard "--cpunodebind=0 --membind=0"
            start_bwmon
            ;;
        "consensus")
            local cluster_prefix="$MSCRUSH_CLUSTER_PREFIX"
            local cluster_pattern="${cluster_prefix}-c*.txt"

            local consensus_dir="$OUTPUT_DIR/consensus"
            mkdir -p "$consensus_dir"

            local consensus_prefix="$consensus_dir/${SUITE}_${WORKLOAD}_${MSCRUSH_SIZE}"
            if [[ -n "$CURRENT_ITERATION" ]]; then
                consensus_prefix+="_iter${CURRENT_ITERATION}"
            fi
            consensus_prefix+="_${MSCRUSH_CONSENSUS_PREFIX}"

            local binary_args="-c $cluster_pattern"
            binary_args+=" -f $MSCRUSH_INPUT_FILES"
            binary_args+=" -d $MSCRUSH_CONSENSUS_DECIMAL"
            binary_args+=" -s '$MSCRUSH_DELIMITER'"
            binary_args+=" -t \"$MSCRUSH_CONSENSUS_TITLE\""
            binary_args+=" -p \"$consensus_prefix\""

            echo "Command preview: $MSCRUSH_CONSENSUS_BIN $binary_args"
            create_workload_wrapper "$WRAPPER" "$PIDFILE" "$MSCRUSH_CONSENSUS_BIN" "$binary_args" ""

            echo "Launching msCRUSH consensus generation..."
            echo "Using cluster files: $cluster_pattern"
            echo "MGF pattern: $MSCRUSH_INPUT_FILES"
            echo "Consensus prefix: $consensus_prefix"

            run_workload_standard "--cpunodebind=0 --membind=0"
            start_bwmon
            ;;
        *)
            echo "ERROR: Unknown phase '$MSCRUSH_PHASE'" >&2
            exit 1
            ;;
    esac
}

run_strace_mscrush(){
    local workload=$1

    if [[ "$MSCRUSH_PHASE" != "cluster" ]]; then
        echo "ERROR: strace support only exists for clustering phase" >&2
        exit 1
    fi

    local cluster_dir="$OUTPUT_DIR/clusters"
    mkdir -p "$cluster_dir"
    local cluster_prefix="$cluster_dir/strace_clusters"

    taskset 0xFF strace -e mmap,munmap -o mscrush_${workload}_strace.log \
        "$MSCRUSH_BIN" \
        -f $MSCRUSH_INPUT_FILES \
        -t $MSCRUSH_THREADS \
        -n $MSCRUSH_HASH_FUNCS \
        -i $MSCRUSH_ITERATIONS \
        -s $MSCRUSH_MIN_SIMILARITY \
        -l $MSCRUSH_MIN_MZ \
        -r $MSCRUSH_MAX_MZ \
        -d "$MSCRUSH_DELIMITER" \
        -c "$cluster_prefix" > /dev/null

    workload_pid=$!
}

clean_mscrush(){
    stop_bwmon
}
