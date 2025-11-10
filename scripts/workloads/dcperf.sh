#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_dcperf(){
    # DCPerf feedsim configuration
    # These match the defaults in feedsim's run.sh
    IS_SMT_ON="$(cat /sys/devices/system/cpu/smt/active)"

    # Thrift threads: scale with logical CPUs till 216
    THRIFT_THREADS="$(echo "define min (a, b) { if (a <= b) return (a); return (b); }; min($(nproc), 216)" | bc)"
    EVENTBASE_THREADS=4
    SRV_THREADS=8

    if [[ "$IS_SMT_ON" = 1 ]]; then
        RANKING_THREADS="$(( $(nproc) * 7/20))"  # 7/20 is 0.35 cpu factor
        SRV_IO_THREADS="$(echo "define min (a, b) { if (a <= b) return (a); return (b); }; min($(nproc) * 7/20, 55)" | bc)"
    else
        RANKING_THREADS="$(( $(nproc) * 15/20))"  # 15/20 is 0.75 cpu factor
        SRV_IO_THREADS="$(echo "define min (a, b) { if (a <= b) return (a); return (b); }; min($(nproc) * 11/20, 55)" | bc)"
    fi

    # Server ports
    FEEDSIM_PORT=11222
    MONITOR_PORT=$((FEEDSIM_PORT - 1000))

    # Workload parameters
    GRAPH_SCALE=21
    GRAPH_SUBSET=2000000
    NUM_OBJECTS=2000
    GRAPH_MAX_ITERS=1
    ICACHE_ITERATIONS=1600000

    # Warmup and duration for fixed QPS experiments
    WARMUP_TIME=120
    FIXED_QPS_DURATION=300

    echo "DCPerf feedsim configuration:"
    echo "  THRIFT_THREADS: $THRIFT_THREADS"
    echo "  RANKING_THREADS: $RANKING_THREADS"
    echo "  SRV_IO_THREADS: $SRV_IO_THREADS"
    echo "  SMT: $IS_SMT_ON"
}

build_dcperf(){
    local workload=$1

    case "$workload" in
        "feedsim")
            echo "Building feedsim..."
            # Check if already built
            if [[ -f "$CUR_PATH/DCPerf/benchmarks/feedsim/src/build/workloads/ranking/LeafNodeRank" ]]; then
                echo "feedsim appears to be already built."
                return 0
            fi

            # Build using the install script
            cd "$CUR_PATH/DCPerf/packages/feedsim"

            # Detect architecture and run appropriate install script
            ARCH=$(uname -m)
            if [[ "$ARCH" == "x86_64" ]]; then
                if [[ -f "install_feedsim_x86_64_ubuntu.sh" ]]; then
                    echo "Running feedsim installation (may require sudo password)..."
                    sudo bash install_feedsim_x86_64_ubuntu.sh
                else
                    sudo bash install_feedsim.sh
                fi
            elif [[ "$ARCH" == "aarch64" ]]; then
                sudo bash install_feedsim_aarch64.sh
            else
                echo "ERROR: Unsupported architecture: $ARCH"
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown dcperf workload: $workload"
            return 1
            ;;
    esac
}

run_dcperf(){
    local workload=$1

    case "$workload" in
        "feedsim")
            run_feedsim
            ;;
        *)
            echo "ERROR: Unknown dcperf workload: $workload"
            return 1
            ;;
    esac
}

run_feedsim(){
    local workload="feedsim"

    # Generate filenames using utility function
    generate_workload_filenames "$workload"

    # Create a custom wrapper for feedsim since it's more complex
    # feedsim runs a server (LeafNodeRank) and then a client (DriverNodeRank)
    # We need to track the server PID for monitoring

    local feedsim_root="$CUR_PATH/DCPerf/benchmarks/feedsim"
    local feedsim_src="$feedsim_root/src"
    local result_file="${OUTPUT_DIR}/feedsim_results"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        result_file+="_iter${CURRENT_ITERATION}"
    fi
    result_file+=".txt"

    # Verify feedsim is built
    if [[ ! -f "$feedsim_src/build/workloads/ranking/LeafNodeRank" ]]; then
        echo "ERROR: feedsim binaries not found at: $feedsim_src/build/workloads/ranking/LeafNodeRank"
        echo "Please build first."
        return 1
    fi

    echo "Creating wrapper at: $WRAPPER"

    # Create wrapper script that runs feedsim
    # IMPORTANT: We write the LeafNodeRank server PID to PIDFILE, not the wrapper PID
    # This is because instrumentation tools (DAMON, PEBS) need to track the actual server process
    cat > "$WRAPPER" <<'EOF'
#!/bin/bash

# Set up environment
export LD_PRELOAD="$SYS_ALLOC_VAR:$HEMEMPOL_VAR"
export DRAMSIZE="$DRAMSIZE_VAR"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE_VAR"

cd "$FEEDSIM_SRC_VAR"

# Start LeafNodeRank server in background
MALLOC_CONF=narenas:20,dirty_decay_ms:5000 build/workloads/ranking/LeafNodeRank \
    --port="$FEEDSIM_PORT_VAR" \
    --monitor_port="$MONITOR_PORT_VAR" \
    --graph_scale="$GRAPH_SCALE_VAR" \
    --graph_subset="$GRAPH_SUBSET_VAR" \
    --threads="$THRIFT_THREADS_VAR" \
    --cpu_threads="$RANKING_THREADS_VAR" \
    --timekeeper_threads=2 \
    --io_threads="$EVENTBASE_THREADS_VAR" \
    --srv_threads="$SRV_THREADS_VAR" \
    --srv_io_threads="$SRV_IO_THREADS_VAR" \
    --num_objects="$NUM_OBJECTS_VAR" \
    --graph_max_iters="$GRAPH_MAX_ITERS_VAR" \
    --noaffinity \
    --min_icache_iterations="$ICACHE_ITERATIONS_VAR" &

LEAF_PID=$!

# Write the LeafNodeRank server PID (this is what we want to monitor)
echo $LEAF_PID > "$PIDFILE_VAR"

# Wait for server to be ready
echo "Waiting for LeafNodeRank server to start (PID: $LEAF_PID)..."
sleep 90

# Run the workload driver - use fixed QPS mode for simpler testing
CLIENT_MONITOR_PORT=$((MONITOR_PORT_VAR - 1000))
DRIVER_THREADS=$(echo "scale=2; $(nproc) / 5.0 + 0.5 " | bc)
DRIVER_THREADS="${DRIVER_THREADS%.*}"
DRIVER_THREADS=$(echo "define max (a, b) { if (a >= b) return (a); return (b); }; max(${DRIVER_THREADS:-0}, 4)" | bc)

# Run fixed QPS experiment (200 QPS for 2 minutes as a quick test)
scripts/search_qps.sh -s 95p -t 120 -m 60 -q 200 -o "$RESULT_FILE_VAR" \
    -- build/workloads/ranking/DriverNodeRank \
        --server "0.0.0.0:$FEEDSIM_PORT_VAR" \
        --monitor_port "$CLIENT_MONITOR_PORT" \
        --threads="${DRIVER_THREADS}" \
        --connections=4

# Clean shutdown
sleep 5
kill -SIGINT $LEAF_PID 2>/dev/null || true

# Wait for server to exit
wait $LEAF_PID 2>/dev/null || true
EOF

    # Replace variables in the wrapper (can't use heredoc with variable substitution easily)
    sed -i "s|\$PIDFILE_VAR|$PIDFILE|g" "$WRAPPER"
    sed -i "s|\$SYS_ALLOC_VAR|${SYS_ALLOC:-}|g" "$WRAPPER"
    sed -i "s|\$HEMEMPOL_VAR|${HEMEMPOL:-}|g" "$WRAPPER"
    sed -i "s|\$DRAMSIZE_VAR|${DRAMSIZE:-}|g" "$WRAPPER"
    sed -i "s|\$MIN_INTERPOSE_MEM_SIZE_VAR|${MIN_INTERPOSE_MEM_SIZE:-}|g" "$WRAPPER"
    sed -i "s|\$FEEDSIM_SRC_VAR|$feedsim_src|g" "$WRAPPER"
    sed -i "s|\$FEEDSIM_PORT_VAR|$FEEDSIM_PORT|g" "$WRAPPER"
    sed -i "s|\$MONITOR_PORT_VAR|$MONITOR_PORT|g" "$WRAPPER"
    sed -i "s|\$GRAPH_SCALE_VAR|$GRAPH_SCALE|g" "$WRAPPER"
    sed -i "s|\$GRAPH_SUBSET_VAR|$GRAPH_SUBSET|g" "$WRAPPER"
    sed -i "s|\$THRIFT_THREADS_VAR|$THRIFT_THREADS|g" "$WRAPPER"
    sed -i "s|\$RANKING_THREADS_VAR|$RANKING_THREADS|g" "$WRAPPER"
    sed -i "s|\$EVENTBASE_THREADS_VAR|$EVENTBASE_THREADS|g" "$WRAPPER"
    sed -i "s|\$SRV_THREADS_VAR|$SRV_THREADS|g" "$WRAPPER"
    sed -i "s|\$SRV_IO_THREADS_VAR|$SRV_IO_THREADS|g" "$WRAPPER"
    sed -i "s|\$NUM_OBJECTS_VAR|$NUM_OBJECTS|g" "$WRAPPER"
    sed -i "s|\$GRAPH_MAX_ITERS_VAR|$GRAPH_MAX_ITERS|g" "$WRAPPER"
    sed -i "s|\$ICACHE_ITERATIONS_VAR|$ICACHE_ITERATIONS|g" "$WRAPPER"
    sed -i "s|\$RESULT_FILE_VAR|$result_file|g" "$WRAPPER"

    chmod +x "$WRAPPER"

    # Run workload using standard execution
    # Note: feedsim wrapper handles both server and client, so we just need to launch it
    run_workload_standard "--cpunodebind=0 --membind=0"

    start_bwmon
}

clean_dcperf(){
    stop_bwmon

    # Kill any remaining feedsim processes
    pkill -f "LeafNodeRank" 2>/dev/null || true
    pkill -f "DriverNodeRank" 2>/dev/null || true

    return 0
}
