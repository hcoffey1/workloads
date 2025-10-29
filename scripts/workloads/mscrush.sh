#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# Data paths
MSCRUSH_DIR="$CUR_PATH/msCRUSH"
MSCRUSH_DATA_DIR="$MSCRUSH_DIR/mgf"
MSCRUSH_BIN="$MSCRUSH_DIR/bin/mscrush_on_general_charge"

config_mscrush(){
    local config_file="$1"
    local workload="$2"
    
    # Configuration for msCRUSH clustering
    # Workload size options: "small", "medium", "large", "xlarge"
    MSCRUSH_SIZE="${MSCRUSH_SIZE:-medium}"
    
    # Number of threads to use (default: 20 per README)
    MSCRUSH_THREADS="${MSCRUSH_THREADS:-20}"
    
    # Hash functions per hash table (controls collision probability)
    # More hash functions = smaller collision probability = more clusters = faster
    # README suggests: 10 for <1M spectra, 15 for ~10M spectra
    MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
    
    # Clustering iterations (number of hash tables)
    # More iterations = higher collision probability = fewer clusters = slower
    # README suggests: 100 is a good starting point
    MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-100}"
    
    # Minimum similarity threshold for clustering
    # Higher similarity = more clusters = slower
    # README recommends: 0.5 to 0.65
    MSCRUSH_MIN_SIMILARITY="${MSCRUSH_MIN_SIMILARITY:-0.65}"
    
    # m/z range for peak consideration
    MSCRUSH_MIN_MZ="${MSCRUSH_MIN_MZ:-200}"
    MSCRUSH_MAX_MZ="${MSCRUSH_MAX_MZ:-2000}"
    
    # Configure based on workload size
    # Based on empirical testing: small=2s/103MB, medium=7s/150MB, large=11s/193MB
    # Scaling up by increasing iterations and using more data files
    case "$MSCRUSH_SIZE" in
        "small")
            echo "=== Using msCRUSH SMALL configuration ==="
            MSCRUSH_INPUT_FILES="$MSCRUSH_DATA_DIR/D01.part.[0-2].mgf"
            MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
            MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-200}"
            MSCRUSH_THREADS="${MSCRUSH_THREADS:-10}"
            echo "Input: 3 MGF files (~118MB total)"
            echo "Hash functions: $MSCRUSH_HASH_FUNCS (fewer = more collisions = slower)"
            echo "Iterations: $MSCRUSH_ITERATIONS"
            echo "Expected memory: ~500MB-1GB"
            echo "Expected time: ~30-60 seconds"
            ;;
            
        "medium")
            echo "=== Using msCRUSH MEDIUM configuration ==="
            MSCRUSH_INPUT_FILES="$MSCRUSH_DATA_DIR/D01.part.[0-4].mgf"
            MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
            MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-300}"
            MSCRUSH_THREADS="${MSCRUSH_THREADS:-15}"
            echo "Input: 5 MGF files (~184MB total)"
            echo "Hash functions: $MSCRUSH_HASH_FUNCS (fewer = more collisions = slower)"
            echo "Iterations: $MSCRUSH_ITERATIONS"
            echo "Expected memory: ~1-2GB"
            echo "Expected time: ~2-4 minutes"
            ;;
            
        "large")
            echo "=== Using msCRUSH LARGE configuration ==="
            MSCRUSH_INPUT_FILES="$MSCRUSH_DATA_DIR/D01.part.[0-6].mgf"
            MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
            MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-400}"
            MSCRUSH_THREADS="${MSCRUSH_THREADS:-20}"
            echo "Input: 7 MGF files (~252MB total)"
            echo "Hash functions: $MSCRUSH_HASH_FUNCS (fewer = more collisions = slower)"
            echo "Iterations: $MSCRUSH_ITERATIONS"
            echo "Expected memory: ~2-4GB"
            echo "Expected time: ~5-10 minutes"
            ;;
            
        "xlarge")
            echo "=== Using msCRUSH XLARGE configuration ==="
            MSCRUSH_INPUT_FILES="$MSCRUSH_DATA_DIR/D01.part.*.mgf"
            MSCRUSH_HASH_FUNCS="${MSCRUSH_HASH_FUNCS:-15}"
            MSCRUSH_ITERATIONS="${MSCRUSH_ITERATIONS:-500}"
            MSCRUSH_THREADS="${MSCRUSH_THREADS:-20}"
            echo "Input: All 10 MGF files (~375MB total)"
            echo "Hash functions: $MSCRUSH_HASH_FUNCS (fewer = more collisions = slower)"
            echo "Iterations: $MSCRUSH_ITERATIONS"
            echo "Expected memory: ~4-8GB"
            echo "Expected time: ~10-20 minutes"
            ;;
            
        *)
            echo "ERROR: Unknown size '$MSCRUSH_SIZE'"
            echo "Valid options: small, medium, large, xlarge"
            return 1
            ;;
    esac
    
    # Export for use in run function
    export MSCRUSH_INPUT_FILES MSCRUSH_THREADS MSCRUSH_HASH_FUNCS MSCRUSH_ITERATIONS
    export MSCRUSH_MIN_SIMILARITY MSCRUSH_MIN_MZ MSCRUSH_MAX_MZ MSCRUSH_SIZE
    
    echo "Threads: $MSCRUSH_THREADS"
    echo "Similarity threshold: $MSCRUSH_MIN_SIMILARITY"
    echo "m/z range: $MSCRUSH_MIN_MZ - $MSCRUSH_MAX_MZ"
    echo "=============================="
}

build_mscrush(){
    local workload=$1

    echo "Building msCRUSH..."
    pushd $MSCRUSH_DIR > /dev/null

    # Check if already built
    if [[ -f "$MSCRUSH_BIN" ]]; then
        echo "msCRUSH binaries already exist. Rebuilding..."
    fi

    # Run install script (it compiles both clustering and consensus tools)
    # The install.sh script prompts for overwrite, so we'll just compile directly
    pushd src/app > /dev/null
    
    echo "Compiling mscrush_on_general_charge..."
    bash compile_mscrush_on_general_charge.sh
    
    echo "Compiling generate_consensus_spectrum_for_mscrush..."
    bash compile_generate_consensus_spectrum_for_mscrush.sh
    
    # Move binaries to bin directory
    mkdir -p "$MSCRUSH_DIR/bin"
    mv -f mscrush_on_general_charge "$MSCRUSH_DIR/bin/"
    mv -f generate_consensus_spectrum_for_mscrush "$MSCRUSH_DIR/bin/"
    
    popd > /dev/null

    # Verify binary was created
    if [[ ! -f "$MSCRUSH_BIN" ]]; then
        echo "ERROR: mscrush binary not found after build"
        popd
        exit 1
    fi

    echo "msCRUSH built successfully"
    popd > /dev/null
}

run_mscrush(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Prepare output directory for clusters
    local cluster_dir="$OUTPUT_DIR/clusters"
    mkdir -p "$cluster_dir"
    
    # Output file prefix
    local cluster_prefix="$cluster_dir/${SUITE}_${WORKLOAD}_${MSCRUSH_SIZE}"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        cluster_prefix+="_iter${CURRENT_ITERATION}"
    fi
    cluster_prefix+="_clusters"
    
    # Build msCRUSH arguments
    local binary_path="$MSCRUSH_BIN"
    local binary_args="-f $MSCRUSH_INPUT_FILES"
    binary_args+=" -t $MSCRUSH_THREADS"
    binary_args+=" -n $MSCRUSH_HASH_FUNCS"
    binary_args+=" -i $MSCRUSH_ITERATIONS"
    binary_args+=" -s $MSCRUSH_MIN_SIMILARITY"
    binary_args+=" -l $MSCRUSH_MIN_MZ"
    binary_args+=" -r $MSCRUSH_MAX_MZ"
    binary_args+=" -c $cluster_prefix"
    
    # Create wrapper script
    local extra_env=""
    
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "$binary_args" "$extra_env"
    
    echo "Starting msCRUSH clustering..."
    echo "Size configuration: $MSCRUSH_SIZE"
    echo "Input files: $MSCRUSH_INPUT_FILES"
    echo "Output prefix: $cluster_prefix"
    echo "This may take a while depending on dataset size..."
    
    # Use standard workload execution
    # msCRUSH uses OpenMP internally, so bind to node 0
    run_workload_standard "--cpunodebind=0 --membind=0"
    
    start_bwmon
}

run_strace_mscrush(){
    local workload=$1

    echo "Running msCRUSH with strace..."
    
    # Prepare output directory
    local cluster_dir="$OUTPUT_DIR/clusters"
    mkdir -p "$cluster_dir"
    
    local cluster_prefix="$cluster_dir/strace_clusters"
    
    taskset 0xFF strace -e mmap,munmap -o mscrush_${workload}_strace.log \
        $MSCRUSH_BIN \
        -f $MSCRUSH_INPUT_FILES \
        -t $MSCRUSH_THREADS \
        -n $MSCRUSH_HASH_FUNCS \
        -i $MSCRUSH_ITERATIONS \
        -s $MSCRUSH_MIN_SIMILARITY \
        -l $MSCRUSH_MIN_MZ \
        -r $MSCRUSH_MAX_MZ \
        -c $cluster_prefix > /dev/null

    workload_pid=$!
}

clean_mscrush(){
    stop_bwmon
    return
}
