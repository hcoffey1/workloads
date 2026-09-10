#!/usr/bin/env bash
# =============================================================================
# app_regions_test.sh — hardware-free tests for the --app-regions path.
#
# Runs the benchmark against tests/fake_regent.so (LD_PRELOAD), which satisfies
# the dlsym lookup and logs every registration, so the exact ranges the workload
# declares can be asserted with no NUMA, no PEBS and no libarms_kernel.so.
#
#   bash tests/app_regions_test.sh
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SELF_DIR")"
BIN="$BENCH_DIR/micro_interference"
FAKE="$SELF_DIR/fake_regent.so"

PASS=0; FAIL=0
ok()   { echo "PASS [$1]"; PASS=$((PASS+1)); }
bad()  { echo "FAIL [$1]: $2"; FAIL=$((FAIL+1)); }

# Build both if missing or stale.
if [[ ! -x "$BIN" || "$BENCH_DIR/micro_interference.cpp" -nt "$BIN" ]]; then
    g++ -O2 -std=c++17 -pthread -Wall -Wextra \
        "$BENCH_DIR/micro_interference.cpp" -o "$BIN" || exit 1
fi
if [[ ! -f "$FAKE" || "$SELF_DIR/fake_regent.c" -nt "$FAKE" ]]; then
    gcc -shared -fPIC -O0 -o "$FAKE" "$SELF_DIR/fake_regent.c" || exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/reg.csv"

# Run the benchmark briefly. Args after the fixed ones are per-case.
# 2 MB is the migration granularity, so every size here is a multiple of it.
run_bench() {   # <stdout-file> <extra args...>
    local out="$1"; shift
    : > "$LOG"
    FAKE_REGENT_LOG="$LOG" LD_PRELOAD="$FAKE" \
    "$BIN" --duration 1 --sample-period 1000 --startup-delay 0 \
           --seq-runtime 1 --zipf-runtime 1 "$@" > "$out" 2>&1
    echo $?
}

field() { awk -F, -v r="$1" -v c="$2" '$3==r{print $c}' "$LOG"; }

# ---- both zones: exact boundaries, gap excluded ----------------------------
# Sequential slices are carved from the start of one mapping; the zipfian region
# sits after a 1 GB gap. Two 64 MB slices => one 128 MB sequential range.
rc=$(run_bench "$WORK/both.out" --seq-regions 2 --seq-region-mb 64 \
        --zipf-region-mb 128 --app-regions \
        --seq-policy simple_frequency --seq-fast 32M \
        --zipf-policy evolve --zipf-fast 16M)
if [[ "$rc" != 0 ]]; then
    bad "both zones" "benchmark exited $rc"
else
    [[ "$(wc -l < "$LOG")" == 2 ]] && ok "both zones: exactly two registrations" \
        || bad "both zones" "expected 2 registrations, got $(wc -l < "$LOG")"

    seq_size=$(field 1 2); zipf_size=$(field 0 2)
    [[ "$seq_size" == "$((128 * 1024 * 1024))" ]] \
        && ok "sequential range covers both slices, nothing more" \
        || bad "sequential size" "want 134217728 got $seq_size"
    [[ "$zipf_size" == "$((128 * 1024 * 1024))" ]] \
        && ok "zipfian range is the zipfian region" \
        || bad "zipfian size" "want 134217728 got $zipf_size"

    # The 1 GB gap must fall outside both ranges: seq ends well before zipf
    # starts, and the space between them is registered to nobody.
    seq_base=$(field 1 1); zipf_base=$(field 0 1)
    gap=$(( zipf_base - (seq_base + seq_size) ))
    [[ "$gap" -ge $((1024 * 1024 * 1024)) ]] \
        && ok "1 GB gap left unregistered ($gap bytes between ranges)" \
        || bad "gap" "only $gap bytes between the two ranges"

    [[ "$(field 1 4)" == "simple_frequency" && "$(field 0 4)" == "evolve" ]] \
        && ok "per-zone policy names" \
        || bad "policies" "seq=$(field 1 4) zipf=$(field 0 4)"
    [[ "$(field 1 5)" == "$((32 * 1024 * 1024))" && "$(field 0 5)" == "$((16 * 1024 * 1024))" ]] \
        && ok "per-zone budgets parsed with one-letter units" \
        || bad "budgets" "seq=$(field 1 5) zipf=$(field 0 5)"

    # Registration must precede the ROI, so the whole measured run is owned.
    reg_line=$(grep -n "REGENT regions registered" "$WORK/both.out" | cut -d: -f1)
    roi_line=$(grep -n "ROI_START\|===ROI" "$WORK/both.out" | head -1 | cut -d: -f1)
    if [[ -n "$reg_line" && -n "$roi_line" && "$reg_line" -lt "$roi_line" ]]; then
        ok "registration happens before the ROI"
    else
        bad "ordering" "register=$reg_line roi=$roi_line"
    fi
fi

# ---- zipfian only: the disabled zone is not registered ---------------------
rc=$(run_bench "$WORK/zipf.out" --seq-regions 0 --zipf-region-mb 64 \
        --app-regions --zipf-policy evolve --zipf-fast 16M)
if [[ "$rc" != 0 ]]; then
    bad "zipf only" "benchmark exited $rc"
else
    [[ "$(wc -l < "$LOG")" == 1 && -n "$(field 0 1)" ]] \
        && ok "zipfian-only run registers just the zipfian zone" \
        || bad "zipf only" "log: $(cat "$LOG")"
fi

# A Zipfian-only run must still get the startup delay, which used to sit inside
# the sequential-only branch.
start=$(date +%s%N)
run_bench "$WORK/delay.out" --seq-regions 0 --zipf-region-mb 64 \
    --startup-delay 2 --app-regions --zipf-policy evolve --zipf-fast 16M \
    > /dev/null
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[[ "$elapsed_ms" -ge 2000 ]] \
    && ok "startup delay applies to a Zipfian-only run (${elapsed_ms}ms)" \
    || bad "delay" "only ${elapsed_ms}ms elapsed; delay was skipped"

# ---- sequential only -------------------------------------------------------
rc=$(run_bench "$WORK/seq.out" --seq-regions 3 --seq-region-mb 32 \
        --zipf-region-mb 0 --app-regions \
        --seq-policy simple_frequency --seq-fast 8M)
if [[ "$rc" != 0 ]]; then
    bad "seq only" "benchmark exited $rc"
else
    [[ "$(wc -l < "$LOG")" == 1 && "$(field 1 2)" == "$((96 * 1024 * 1024))" ]] \
        && ok "three slices register as one 96 MB range" \
        || bad "seq only" "log: $(cat "$LOG")"
fi

# ---- failures abort rather than running unmanaged --------------------------
: > "$LOG"
out=$(FAKE_REGENT_LOG="$LOG" FAKE_REGENT_FAIL_ON=0 LD_PRELOAD="$FAKE" \
      "$BIN" --duration 1 --startup-delay 0 --seq-regions 1 --seq-region-mb 32 \
             --zipf-region-mb 64 --app-regions \
             --seq-policy simple_frequency --seq-fast 8M \
             --zipf-policy evolve --zipf-fast 8M 2>&1)
rc=$?
[[ "$rc" != 0 ]] && ok "a failed registration aborts the run (rc=$rc)" \
    || bad "failure" "run continued after a registration failure"
grep -q "ROI" <<< "$out" && bad "failure" "reached the ROI after failing" \
    || ok "no measurement after a failed registration"

# Without the fake preloaded there is no symbol to resolve: abort, never fall
# back to inferred clustering.
out=$("$BIN" --duration 1 --startup-delay 0 --seq-regions 1 --seq-region-mb 32 \
             --zipf-region-mb 0 --app-regions \
             --seq-policy simple_frequency --seq-fast 8M 2>&1)
rc=$?
[[ "$rc" != 0 ]] && grep -q "not available" <<< "$out" \
    && ok "missing symbol aborts with a clear message" \
    || bad "missing symbol" "rc=$rc out=$out"

# ---- config validation -----------------------------------------------------
out=$("$BIN" --duration 1 --seq-regions 1 --seq-region-mb 32 --zipf-region-mb 0 \
             --app-regions --seq-fast 8M 2>&1)
[[ $? != 0 ]] && grep -q "needs --seq-policy" <<< "$out" \
    && ok "enabled zone without a policy is rejected before allocating" \
    || bad "validation" "out=$out"

out=$("$BIN" --duration 1 --seq-regions 1 --seq-region-mb 32 --zipf-region-mb 0 \
             --app-regions --seq-policy simple_frequency --seq-fast 8GB 2>&1)
[[ $? != 0 ]] && ok "size strings reject the two-letter form (8GB)" \
    || bad "size parsing" "8GB was accepted"

# ---- default path is unchanged ---------------------------------------------
: > "$LOG"
rc=$(run_bench "$WORK/default.out" --seq-regions 1 --seq-region-mb 32 \
        --zipf-region-mb 64)
if [[ "$rc" == 0 && ! -s "$LOG" ]]; then
    ok "without --app-regions nothing is registered"
else
    bad "default" "rc=$rc log=$(cat "$LOG")"
fi

echo "================================"
echo "app_regions: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
