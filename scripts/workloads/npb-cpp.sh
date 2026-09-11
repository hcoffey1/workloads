#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"
set -x

config_npb-cpp(){
    NPB_CLASS=${NPB_CLASS:-D}
    num_threads=8
}

build_npb-cpp(){
    local workload=$1
    # NPB's benchmark subdirs invoke ../sys/setparams to generate npbparams.hpp;
    # with `make -j` the sys/setparams build can race with that invocation, so
    # build setparams sequentially first.
    # `make clean` first: NPB doesn't reliably invalidate stale .o/npbparams.hpp
    # when only CLASS changes, so switching from e.g. C→D otherwise yields the
    # old binary. Cheap to rebuild from scratch.
    (cd $CUR_PATH/NPB-CPP/NPB-OMP && make clean) && \
    (cd $CUR_PATH/NPB-CPP/NPB-OMP/sys && make) && \
    (cd $CUR_PATH/NPB-CPP/NPB-OMP && make -j$(nproc) $workload CLASS=$NPB_CLASS)
}

# Application-defined REGENT zones for CG, see docs/npb_cg_regions.md.
# NPB_CG_REGION_MODE selects off/layout/application; application mode needs
# NPB_CG_<ZONE>_POLICY and _FAST for every zone.
NPB_CG_ZONES=(matrix gather_vectors streaming_state)

_npb_zone_args(){
    local workload=$1 mode=${NPB_CG_REGION_MODE:-off}
    ZONE_ARGS=""
    ZONE_EXTRA_ENV=""
    if [[ "$workload" != cg ]]; then
        if [[ "$mode" != off ]]; then
            echo "ERROR: NPB_CG_REGION_MODE applies to the cg workload only" >&2
            return 1
        fi
        return 0
    fi
    regent_zones_prepare_args NPB_CG "$mode" "${NPB_CG_ZONES[@]}"
}

run_npb-cpp(){
    local workload=$1

    _npb_zone_args "$workload" || return
    local extra_env="export OMP_NUM_THREADS=\"$num_threads\""
    [[ -n "$ZONE_EXTRA_ENV" ]] && extra_env+=$'\n'"$ZONE_EXTRA_ENV"

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    local binary="$CUR_PATH/NPB-CPP/NPB-OMP/bin/${workload}.${NPB_CLASS}"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary" "${ZONE_ARGS# }" "$extra_env"
    if [[ "${NPB_CG_REGION_MODE:-off}" != off ]]; then
        python3 "$CUR_PATH/scripts/workloads/regions_metadata.py" \
            --root "$CUR_PATH" --binary "$binary" --wrapper "$WRAPPER" \
            --output "${STDOUT%_stdout.txt}_regions.json" --env-prefix NPB_ \
            --file NPB-CPP/NPB-OMP/CG/cg.cpp --file NPB-CPP/NPB-OMP/CG/Makefile \
            --file NPB-CPP/NPB-OMP/config/make.def --file NPB-CPP/NPB-OMP/CG/npbparams.hpp \
            --file scripts/workloads/npb-cpp.sh || return
    fi

    # Use standard workload execution
    run_workload_standard

    start_bwmon
}

run_strace_npb-cpp(){
    local workload=$1
    # STUB
    workload_pid=$!
}

clean_npb-cpp(){
    stop_bwmon
    return
}
