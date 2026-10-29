#!/bin/bash
# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# Mitosis B+tree: build tree of N keys, then L random lookups (OpenMP-parallel).
config_btree(){
    num_threads=${BTREE_THREADS:-4}
    nelements=${BTREE_ELEMENTS:-537000000}  # ~32 GB RSS at ~64 B/element
    nlookup=${BTREE_LOOKUPS:-3700000000}  # ~2 min of lookups at 4 threads, 32 GB
}

build_btree(){
    (cd $CUR_PATH/mitosis-workload-btree && make -j$(nproc))
}

run_btree(){
    local workload=$1

    generate_workload_filenames "$workload"

    # Binary signals via fixed /tmp files; stale ones owned by another user make
    # the sudo-launched run fail (fs.protected_regular), so clear them first.
    run_sudo rm -f /tmp/mitosis-btree-bench.ready /tmp/mitosis-btree-bench.done

    # Args after "--" go to the benchmark's inner getopt.
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/mitosis-workload-btree/bin/bench_btree_mt" \
        "-- -n $nelements -l $nlookup" "export OMP_NUM_THREADS=\"$num_threads\""

    run_workload_standard
    start_bwmon
}

clean_btree(){
    stop_bwmon
    return
}
