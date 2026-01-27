#!/bin/bash

# Configuration Parameters
FAST_MEM_VALUES=("32M")
ITERATIONS=10
ZIPF_VALUES=("1000000000" "2000000000" "3000000000" "4000000000")
HYBRID_SIZES=("2M" "4M" "8M" "16M" "32M")
#HYBRID_SIZES=("16M")
LIB_ARMS_PATH=~/arms/libarms_kernel.so

# Ensure output directories are created safely
for FAST_MEM in "${FAST_MEM_VALUES[@]}"; do
    for ZIPF_SIZE in "${ZIPF_VALUES[@]}"; do
        echo "========================================"
        echo "Starting experiments for FAST_MEM=$FAST_MEM ZIPF_SIZE=$ZIPF_SIZE"
        echo "========================================"

        # Set Zipf Workload Size
        export PHASE_ZIPF_WORKLOAD_SIZE=$ZIPF_SIZE

        # Prepare Output Directory
        OUTPUT_DIR="results_${FAST_MEM}_zipf${ZIPF_SIZE}"
        mkdir -p "$OUTPUT_DIR"

        # ------------------------------------------------------------------
        # 1. Baseline ARMS
        # ------------------------------------------------------------------
        echo "Running Baseline ARMS"
        REGENT_FAST_MEMORY=$FAST_MEM \
        ARMS_POLICY=ARMS \
        HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
        -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_arms" \
        -r $ITERATIONS --use-cgroup

        # ------------------------------------------------------------------
        # 2. Baseline LRU (lru_ptscan)
        # ------------------------------------------------------------------
        echo "Running Baseline LRU"
        REGENT_FAST_MEMORY=$FAST_MEM \
        ARMS_POLICY=lru_ptscan \
        HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
        -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_lru_ptscan" \
        -r $ITERATIONS --use-cgroup

        # ------------------------------------------------------------------
        # 3. Hybrid Variations
        # ------------------------------------------------------------------
        for SIZE in "${HYBRID_SIZES[@]}"; do
            echo "Running Hybrid with SIZE=$SIZE"
            REGENT_FAST_MEMORY=$FAST_MEM \
            REGENT_REGIONS=lru_ptscan:0x7fffc5400000-0x7ffff13fffff:$SIZE \
            HEMEMPOL=$LIB_ARMS_PATH ./run.sh \
            -b micro_phase -w micro_phase -o "$OUTPUT_DIR/results_hybrid_$SIZE" \
            -r $ITERATIONS --use-cgroup
        done

    done
done
