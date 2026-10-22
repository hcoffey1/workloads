#!/bin/bash
# Smoke-run one workload per suite through run.sh to find stale workloads.
# The lazy build/download phase gets BUILD_CAP seconds; once run.sh prints
# "Running workload:" the run gets RUN_CAP seconds, then it is killed.
# A run still alive at the cap counts as RUNNING (it started fine).
#
# Usage: scripts/smoke.sh [suite:workload ...]   (default: one per suite)
# Output: $OUT/<suite>_<workload>.log, $OUT/summary.tsv
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUN_CAP=${RUN_CAP:-300}
BUILD_CAP=${BUILD_CAP:-2700}
OUT=${OUT:-$ROOT/smoke_results}

DEFAULT=(
    xsbench:xsbench graph500:graph500 gapbs:bfs_twitter flexkvs:flexkvs
    silo:silo merci:merci liblinear:liblinear gups:gups masim:masim
    npb-cpp:cg cloverleaf:cloverleaf minimap2:minimap2 llama_cpp:llama-bench
    dcperf:feedsim memcached:memcached cachelib:cachelib ann-solo:toy
    mscrush:mscrush spec:mcf spec2026:lbm ogb:products duckdb:tpcds_sf100_q01
    faiss:sift1M renaissance:als micro_interference:micro_interference
    micro_phase:micro_phase seq_slope_bench:seq_slope_bench
)
jobs=("$@"); (( ${#jobs[@]} )) || jobs=("${DEFAULT[@]}")

mkdir -p "$OUT"
[[ -f $OUT/summary.tsv ]] || printf 'suite\tworkload\tstatus\tbuild_s\trun_s\tlast_error\n' > "$OUT/summary.tsv"

for job in "${jobs[@]}"; do
    suite=${job%%:*} wl=${job#*:}
    log=$OUT/${suite}_${wl}.log
    echo ">> $suite/$wl (log: $log)"

    cd "$ROOT"
    setsid ./run.sh -b "$suite" -w "$wl" -o "$OUT/${suite}_${wl}" > "$log" 2>&1 < /dev/null &
    pid=$!
    phase=build t0=$SECONDS build_s=0 status=
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $phase == build ]] && grep -q '^Running workload:' "$log"; then
            build_s=$(( SECONDS - t0 )) phase=run t0=$SECONDS
        fi
        cap=$BUILD_CAP; [[ $phase == run ]] && cap=$RUN_CAP
        if (( SECONDS - t0 > cap )); then
            # Workloads run as root under `sudo numactl`, so kill the group as root.
            sudo kill -TERM -- "-$pid" 2>/dev/null; sleep 10
            sudo kill -KILL -- "-$pid" 2>/dev/null
            [[ $phase == run ]] && status=RUNNING || status=BUILD_TIMEOUT
            break
        fi
        sleep 5
    done
    wait "$pid"; rc=$?
    [[ $phase == build ]] && build_s=$(( SECONDS - t0 )) run_s=0 || run_s=$(( SECONDS - t0 ))
    [[ -n $status ]] || { (( rc == 0 )) && status=PASS || status="FAIL($rc)"; }
    err=$(grep -iE 'error|fail|not found|no such' "$log" | tail -1 | tr '\t' ' ' | cut -c1-200)

    # A killed run.sh skips sys_cleanup; undo its system tweaks and stray monitors.
    echo 2 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    sudo killall -q bwmon mpstat perf_monitor 2>/dev/null

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$wl" "$status" "$build_s" "$run_s" "$err" >> "$OUT/summary.tsv"
    echo "   $status (build ${build_s}s, run ${run_s}s)"
done
column -t -s $'\t' "$OUT/summary.tsv"
