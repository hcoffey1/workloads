#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_merci(){
    num_threads=${MERCI_THREADS:-8}
    num_reps=${MERCI_REPEATS:-20}
}

build_merci(){
    (cd "$CUR_PATH/MERCI/4_performance_evaluation" && make -j"$(nproc)")
}

# create_workload_wrapper emits a /bin/sh script: use POSIX single quoting,
# not bash printf %q (which can emit bash-only dollar-quoted strings).
merci_quote(){
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

merci_prepare_args(){
    local mode=${MERCI_REGION_MODE:-off} option
    local -a args=(--dataset "${MERCI_DATASET:-amazon_All}" -r "$num_reps" -c "$num_threads")
    MERCI_EXTRA_ENV="export HOME=$(merci_quote "$CUR_PATH")"
    case "$mode" in
        application)
            for option in MERCI_EMBEDDING_POLICY MERCI_EMBEDDING_FAST MERCI_OUTPUT_POLICY MERCI_OUTPUT_FAST; do
                if [[ -z "${!option:-}" ]]; then
                    echo "ERROR: $option is required for MERCI application regions" >&2
                    return 1
                fi
            done
            args+=(--app-regions --app-region "embedding:$MERCI_EMBEDDING_POLICY:$MERCI_EMBEDDING_FAST"
                --app-region "output:$MERCI_OUTPUT_POLICY:$MERCI_OUTPUT_FAST")
            MERCI_EXTRA_ENV+=$'\nunset REGENT_NO_CLUSTERING REGENT_CLUSTER_CONFIG REGENT_REBALANCER'
            MERCI_EXTRA_ENV+=$'\nexport REGENT_REGION_MODE=application'
            ;;
        layout)
            args+=(--region-layout-only)
            MERCI_EXTRA_ENV+=$'\nunset LD_PRELOAD REGENT_REGION_MODE'
            ;;
        off) ;;
        *) echo "ERROR: MERCI_REGION_MODE must be off, layout, or application" >&2; return 1 ;;
    esac
    if [[ "$mode" != application ]]; then
        for option in MERCI_EMBEDDING_POLICY MERCI_EMBEDDING_FAST MERCI_OUTPUT_POLICY MERCI_OUTPUT_FAST; do
            if [[ -n "${!option:-}" ]]; then
                echo "ERROR: $option requires MERCI_REGION_MODE=application" >&2
                return 1
            fi
        done
    fi
    [[ -n "${MERCI_SHUFFLE_SEED:-}" ]] && args+=(--shuffle-seed "$MERCI_SHUFFLE_SEED")
    [[ -n "${MERCI_WARMUPS:-}" ]] && args+=(--warmups "$MERCI_WARMUPS")
    case "${MERCI_VERIFY:-0}" in
        1) args+=(--verify) ;;
        0) ;;
        *) echo "ERROR: MERCI_VERIFY must be 0 or 1" >&2; return 1 ;;
    esac
    MERCI_EXTRA_ENV+=$'\n'"export NUMA_PLACEMENT=$(merci_quote "${NUMA_PLACEMENT:-slow-bind}")"
    if [[ "$mode" != off ]]; then
        MERCI_EXTRA_ENV+=$'\n'"export OMP_NUM_THREADS=$(merci_quote "$num_threads")"
    fi
    MERCI_ARGS=""
    for option in "${args[@]}"; do
        MERCI_ARGS+=" $(merci_quote "$option")"
    done
}

run_merci(){
    local workload=$1
    merci_prepare_args || return

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Create wrapper using utility function (with custom HOME environment variable)
    local binary="$CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary" "$MERCI_ARGS" "$MERCI_EXTRA_ENV" || return
    if [[ "${MERCI_REGION_MODE:-off}" != off ]]; then
        python3 "$CUR_PATH/scripts/workloads/merci_metadata.py" "$CUR_PATH" "$binary" "$WRAPPER" \
            "${MERCI_DATASET:-amazon_All}" "${STDOUT%_stdout.txt}_regions.json" || return
    fi

    # Use standard workload execution
    run_workload_standard || return

    start_bwmon
    start_mpstat
    start_perf_monitor
    start_cpufreq
}

run_strace_merci(){
    if [[ "${MERCI_REGION_MODE:-off}" != off ]]; then
        echo "ERROR: use run_merci or direct binary options for region tracing" >&2
        return 1
    fi
    HOME=$CUR_PATH strace -e mmap,munmap -o merci_merci_strace.log $CUR_PATH/MERCI/4_performance_evaluation/bin/eval_baseline --dataset amazon_All -r $num_reps -c $num_threads
}

clean_merci(){
    stop_bwmon || true
    stop_mpstat || true
    stop_perf_monitor || true
    stop_cpufreq || true
    return
}
