#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_gapbs(){
    num_threads=8
    num_rep=20
    # Synthetic kron scale; GAPBS_GRAPH_SCALE lets smoke runs use a small graph.
    graph_size=${GAPBS_GRAPH_SCALE:-26}
    #graph_size=27
    graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitter.sg
    graph_path_u=$CUR_PATH/gapbs/benchmark/graphs/twitterU.sg
    w_graph_path=$CUR_PATH/gapbs/benchmark/graphs/twitter.wsg
}

build_gapbs(){
    local workload="${1:-}"
    (cd $CUR_PATH/gapbs && make -j$(nproc))
    # Only fetch/build the large real-graph datasets (twitter, ~3 GB download)
    # when a *_twitter workload actually needs them.  Synthetic runs use a
    # generated kron graph (-g <scale>) and need no external files.
    case "$workload" in
        *_twitter) (cd $CUR_PATH/gapbs && make bench-graphs -j 1) ;;
    esac
}

# Resolve a workload name into "<kernel>|<input-args>".
# Plain "bc" → synthetic kron via `-g $graph_size`.
# "bc_twitter" → twitter graph; file format depends on kernel:
#   sssp needs .wsg (weighted), tc needs twitterU.sg (symmetrized), rest use twitter.sg.
_gapbs_resolve(){
    local workload=$1
    local kernel input
    case "$workload" in
        *_twitter)
            kernel=${workload%_twitter}
            case "$kernel" in
                sssp) input="-f $w_graph_path" ;;
                tc)   input="-f $graph_path_u" ;;
                *)    input="-f $graph_path"   ;;
            esac
            ;;
        *)
            kernel=$workload
            input="-g $graph_size"
            ;;
    esac
    echo "$kernel|$input"
}

# Application-defined REGENT zones for PageRank (pr, pr_twitter), see
# docs/gapbs_pr_regions.md. GAPBS_PR_REGION_MODE selects off/layout/application;
# application mode needs GAPBS_PR_<ZONE>_POLICY and _FAST for every zone.
GAPBS_PR_ZONES=(incoming_edges contributions scores vertex_index)

_gapbs_zone_args(){
    local kernel=$1 mode=${GAPBS_PR_REGION_MODE:-off}
    ZONE_ARGS=""
    ZONE_EXTRA_ENV=""
    if [[ "$kernel" != pr ]]; then
        if [[ "$mode" != off ]]; then
            echo "ERROR: GAPBS_PR_REGION_MODE applies to the pr kernel only" >&2
            return 1
        fi
        return 0
    fi
    regent_zones_prepare_args GAPBS_PR "$mode" "${GAPBS_PR_ZONES[@]}"
}

run_gapbs(){
    local workload=$1
    local reps="$num_rep"

    local resolved kernel input
    resolved=$(_gapbs_resolve "$workload")
    kernel=${resolved%%|*}
    input=${resolved#*|}

    if [[ "$kernel" == "tc" ]]; then
        reps=4
    fi

    _gapbs_zone_args "$kernel" || return
    local extra_env="export OMP_NUM_THREADS=\"$num_threads\""
    [[ -n "$ZONE_EXTRA_ENV" ]] && extra_env+=$'\n'"$ZONE_EXTRA_ENV"

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Create wrapper using utility function
    local binary="$CUR_PATH/gapbs/$kernel"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary" "-n \"$reps\" $input$ZONE_ARGS" "$extra_env"
    if [[ "${GAPBS_PR_REGION_MODE:-off}" != off ]]; then
        python3 "$CUR_PATH/scripts/workloads/regions_metadata.py" \
            --root "$CUR_PATH" --binary "$binary" --wrapper "$WRAPPER" \
            --output "${STDOUT%_stdout.txt}_regions.json" --env-prefix GAPBS_ \
            --file gapbs/Makefile --glob gapbs/src '*.cc' --glob gapbs/src '*.h' \
            --file scripts/workloads/gapbs.sh || return
    fi

    # Use standard workload execution
    run_workload_standard

    start_bwmon
}

run_strace_gapbs(){
    local workload=$1
    local resolved kernel input
    resolved=$(_gapbs_resolve "$workload")
    kernel=${resolved%%|*}
    input=${resolved#*|}

    OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o gapbs_${workload}_strace.log $CUR_PATH/gapbs/$kernel -n $num_rep $input &

    workload_pid=$!
}

clean_gapbs(){
    stop_bwmon
    return
}
