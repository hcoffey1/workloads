#!/bin/bash
set -euo pipefail

# Controls
FAST_MEM=${FAST_MEM:-"8G"}
ITERATIONS=${ITERATIONS:-5}
START_SIZE_GB=${START_SIZE_GB:-1}
END_SIZE_GB=${END_SIZE_GB:-16}
REGION_RANGE=${REGION_RANGE:-"0x7ffd00000000-0x7ffeff000000"}
OUTPUT_ROOT=${OUTPUT_ROOT:-"results_pin_control"}

# Default policy = fallback policy. Requested controls map PIN_UP->PIN_FAST, PIN_DOWN->PIN_SLOW.
DEFAULT_POLICIES=("PIN_FAST" "PIN_SLOW")
REGION_POLICIES=("lru" "arms")

printf "Starting pin control hybrid experiment\n"
printf "FAST_MEM=%s ITERATIONS=%s SIZE_RANGE=%s-%sGB\n" "$FAST_MEM" "$ITERATIONS" "$START_SIZE_GB" "$END_SIZE_GB"

#if [ -e /tmp/memeater_control ]; then
#  echo "Updating memeater control to $FAST_MEM"
#  echo "$FAST_MEM" > /tmp/memeater_control
#  echo "Waiting for memeater to settle..."
#  sleep 30
#fi

for default_policy in "${DEFAULT_POLICIES[@]}"; do
  for region_policy in "${REGION_POLICIES[@]}"; do
    for size_gb in $(seq "$START_SIZE_GB" "$END_SIZE_GB"); do
      SIZE="${size_gb}G"
      run_dir="$OUTPUT_ROOT/${default_policy,,}_${region_policy}_${SIZE}"
      mkdir -p "$run_dir"

      echo "Running default=$default_policy region=$region_policy size=$SIZE -> $run_dir"

      REGENT_FAST_MEMORY=$FAST_MEM \
      ARMS_POLICY=$default_policy \
      REGENT_REGIONS=${region_policy}:${REGION_RANGE}:${SIZE} \
      HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
      -b merci -w merci -o "$run_dir" \
      -r "$ITERATIONS"
    done
  done
done
