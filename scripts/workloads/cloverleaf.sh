#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_cloverleaf(){
    WORK_DIR=$CUR_PATH/CloverLeaf/CloverLeaf_OpenMP/
    num_threads=16
    cp $WORK_DIR/InputDecks/clover_bm16_short.in ./clover.in
}

build_cloverleaf(){
    pushd $WORK_DIR

    make COMPILER=GNU -j $(nproc)

    popd
}

run_cloverleaf(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$WORK_DIR/clover_leaf" "" "export OMP_NUM_THREADS=\"$num_threads\""

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"

    # BW Monitoring
    sudo $CUR_PATH/scripts/cipp-workspace/tools/bwmon 500 \
        > ${OUTPUT_DIR}/${SUITE}_${WORKLOAD}_${hemem_policy}_${DRAMSIZE}_bwmon.txt &
    bwmon_pid=$!
}

run_strace_cloverleaf(){
    return
}

clean_cloverleaf(){
    sudo kill "$bwmon_pid"
    rm -f clover.in times.txt logs.txt stats.txt clover.in.tmp clover.out
    return
}
