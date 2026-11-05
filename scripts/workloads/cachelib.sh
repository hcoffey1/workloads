#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_cachelib(){
    #TODO: Update test config, this one is too small.
    cachelib_json=$CUR_PATH/CacheLib/cachelib/cachebench/test_configs/simple_test.json
    return
}

build_cachelib(){
    pushd $CUR_PATH/CacheLib

    # FastFloat (folly dep) is installed by setup.sh prereqs.

    # Earlier sudo builds (e.g. dcperf feedsim) can leave the CMake package registry root-owned, breaking gflags install
    if [[ -d "$HOME/.cmake" ]] && find "$HOME/.cmake" ! -user "$(id -u)" -print -quit | grep -q .; then
        sudo chown -R "$(id -u):$(id -g)" "$HOME/.cmake"
    fi

    ./contrib/build.sh -j -T

    popd
}

run_cachelib(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Create wrapper using utility function
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$CUR_PATH/CacheLib/opt/cachelib/bin/cachebench" "--json_test_config \"$cachelib_json\""

    # Use standard workload execution
    run_workload_standard
}

run_strace_cachelib(){
    return
}

clean_cachelib(){
    rm -f logs.txt stats.txt times.txt
    return
}
