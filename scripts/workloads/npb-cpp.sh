#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"
set -x

config_npb-cpp(){
    # Set TBB paths for later use
    export TBB_ROOT="$CUR_PATH/NPB-CPP/libs/tbb-2020.1"
    export TBB_BIN="$TBB_ROOT/build/linux_intel64_gcc_cc11.4.0_libc2.35_kernel5.1.0_release"

    pushd $TBB_ROOT
    make -j $(nproc)
    popd

    set +u
    source $TBB_BIN/tbbvars.sh
    set -u

    NPB_CLASS=D
}

build_npb-cpp(){
    local workload=$1
    (cd $CUR_PATH/NPB-CPP/NPB-PSTL && make -j$(nproc) $workload CLASS=$NPB_CLASS)
}

run_npb-cpp(){
    local workload=$1

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Prepare TBB environment variables for the wrapper
    local tbb_env="export TBBROOT=\"$TBB_ROOT\"
export CPATH=\"$TBB_ROOT/include:\$CPATH\"
export LIBRARY_PATH=\"$TBB_BIN:\$LIBRARY_PATH\"
export LD_LIBRARY_PATH=\"$TBB_BIN:\$LD_LIBRARY_PATH\""

    # Create wrapper using utility function with TBB environment
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/NPB-CPP/NPB-PSTL/bin/${workload}.${NPB_CLASS}" "" "$tbb_env"

    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"

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
