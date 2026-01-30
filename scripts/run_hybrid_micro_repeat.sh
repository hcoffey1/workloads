#!/bin/bash
set -u

# Configuration Parameters
FAST_MEM="8G"
ITERATIONS=3
ZIPF_SIZE=3000000000
LIB_ARMS_PATH=~/arms/libarms_kernel.so

# Workload Parameters
export PHASE_ZIPF_WORKLOAD_SIZE=$ZIPF_SIZE
export PHASE_ZIPF_REPEATS=1
export PHASE_ZIPF_SLEEP_SEC=60

# Unmap settings to test: 0 (keep mapped), 1 (unmap during sleep)
UNMAP_SETTINGS=(0 1)

for UNMAP in "${UNMAP_SETTINGS[@]}"; do
    export PHASE_ZIPF_UNMAP=$UNMAP

    SUFFIX="nounmap"
    [ "$UNMAP" -eq 1 ] && SUFFIX="unmap"

    SUFFIX=${SUFFIX}_${FAST_MEM}

    echo "=================================================="
    echo "Starting experiments with PHASE_ZIPF_UNMAP=$UNMAP ($SUFFIX)"
    echo "=================================================="

    OUTPUT_DIR="results_micro_repeat_${SUFFIX}"
    mkdir -p "$OUTPUT_DIR"

    # 1. Baseline ARMS
    echo "Running Baseline ARMS"
    REGENT_FAST_MEMORY=$FAST_MEM \
    ARMS_POLICY=ARMS \
    HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
    -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_arms" \
    -r $ITERATIONS --use-cgroup

    # 2. Baseline LRU (lru_ptscan)
    echo "Running Baseline LRU"
    REGENT_FAST_MEMORY=$FAST_MEM \
    ARMS_POLICY=lru_ptscan \
    HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
    -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_lru_ptscan" \
    -r $ITERATIONS --use-cgroup

    # 3. Hybrid 2G
    SIZE="2G"
    echo "Running Hybrid 2G"
    REGENT_FAST_MEMORY=$FAST_MEM \
    REGENT_REGIONS=lru_ptscan:0x7ffde3800000-0x7fffe3dfffff:$SIZE \
    HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
    -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_hybrid_$SIZE" \
    -r $ITERATIONS --use-cgroup

done

echo "All experiments completed."
