#!/bin/bash

# Parameters
FAST_MEM_VALUES=("8G" "16G" "24G")
ITERATIONS=5

#FAST_MEM="8G"
#SIZE="4G"
#OUTPUT_DIR="results_test"
#REGENT_FAST_MEMORY=$FAST_MEM \
#	REGENT_RESULTS_DIR=$OUTPUT_DIR/results_hybrid_$SIZE \
#	REGENT_REGIONS=lru:0x7ffd00000000-0x7ffeff000000:$SIZE \
#	HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
#	-b merci -w merci -o $OUTPUT_DIR/results_hybrid_$SIZE \
#	-r 1
#
#exit

for FAST_MEM in "${FAST_MEM_VALUES[@]}"; do
    echo "========================================"
    echo "Starting experiments for FAST_MEM=$FAST_MEM"
    echo "========================================"

    echo "Updating memeater control to $FAST_MEM"
    echo $FAST_MEM > /tmp/memeater_control
    echo "Waiting for memeater to settle..."
    sleep 30

    OUTPUT_DIR="results_$FAST_MEM"
    mkdir -p $OUTPUT_DIR

    # 1. Baseline ARMS
    echo "Running Baseline ARMS"
    REGENT_FAST_MEMORY=$FAST_MEM \
    ARMS_POLICY=ARMS \
    HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
    -b merci -w merci -o $OUTPUT_DIR/results_arms \
    -r $ITERATIONS

    # 2. Baseline LRU
    echo "Running Baseline LRU"
    REGENT_FAST_MEMORY=$FAST_MEM \
    ARMS_POLICY=lru \
    HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
    -b merci -w merci -o $OUTPUT_DIR/results_lru \
    -r $ITERATIONS

    # 3. Hybrid Loop
    echo "Running Hybrid Loop"
    FAST_MEM_INT=${FAST_MEM%G}
    for i in $(seq 1 20); do
        if [ $i -gt $FAST_MEM_INT ]; then
            break
        fi
        SIZE="${i}G"
        echo "Running with LRU Region Size: $SIZE"

        REGENT_FAST_MEMORY=$FAST_MEM \
        REGENT_REGIONS=lru:0x7ffd00000000-0x7ffeff000000:$SIZE \
        HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
        -b merci -w merci -o $OUTPUT_DIR/results_hybrid_$SIZE \
        -r $ITERATIONS
    done
done
