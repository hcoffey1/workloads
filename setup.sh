#!/bin/bash
#
# setup.sh - build all workloads in this suite.
#
# Prerequisites (submodules, system packages, conda env) are installed serially
# first, then each workload is built as a concurrent background job. Per-job
# status and timing are collected and written to setup_summary.log.
#
# Tunables (env overrides):
#   MAX_PARALLEL  max number of build jobs to run at once   (default 4)
#   J             -j parallelism passed to each make        (default 4)
#   LOGDIR        directory for per-job logs/status         (default ./setup_logs)
#   BUILD_SPEC=0  skip the (heavy) SPEC CPU2017 build
#   SPEC_SRC      path to a SPEC CPU2017 install            (default /proj/instrument-PG0/spec)
#   BUILD_SPEC2026=0  skip the (heavy) SPEC CPU2026 build
#   SPEC2026_ISO  path to the CPU2026 ISO   (default /proj/instrument-PG0/cpu2026-1.0.1.iso)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

MAX_PARALLEL="${MAX_PARALLEL:-8}"
J="${J:-16}"
LOGDIR="${LOGDIR:-$ROOT/setup_logs}"
SUMMARY="${SUMMARY:-$ROOT/setup_summary.log}"

mkdir -p "$LOGDIR"
rm -f "$LOGDIR"/*.status   # clear stale results from a previous run

declare -a JOB_NAMES=()

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

fmt_time() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# apply_patch <patchfile> - idempotently apply a git patch from the cwd.
# Skips if the patch is already applied so re-running setup.sh is safe.
apply_patch() {
    local p="$1"
    if git apply --reverse --check "$p" 2>/dev/null; then
        echo "patch already applied: $p"
    elif git apply --check "$p" 2>/dev/null; then
        git apply "$p" && echo "applied patch: $p"
    else
        echo "WARNING: patch $p does not apply cleanly; attempting anyway" >&2
        git apply "$p"
    fi
}

# _exec_job <name> <cmd...> - run a build, capturing log, exit code and elapsed
# time. Each build runs under `set -e` so the first failing command propagates.
# Exit code 100 from a build is treated as a deliberate SKIP.
_exec_job() {
    local name="$1"; shift
    local log="$LOGDIR/${name}.log"
    local status="$LOGDIR/${name}.status"
    local start end rc
    start=$(date +%s)
    # NB: run the subshell as a *standalone* command, not as an `if` condition.
    # Bash ignores `set -e` for a command used as an if/while/&&/|| condition
    # (even an explicit `set -e` inside it), which would silently mask failures.
    ( set -e; "$@" ) >"$log" 2>&1
    rc=$?
    end=$(date +%s)
    printf '%s|%s|%s\n' "$name" "$rc" "$((end - start))" >"$status"
    return "$rc"
}

# throttle - block until fewer than MAX_PARALLEL background jobs are running.
throttle() {
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
        wait -n 2>/dev/null || true
    done
}

# run_job <name> <cmd...> - launch a build concurrently, respecting MAX_PARALLEL.
run_job() {
    local name="$1"
    JOB_NAMES+=("$name")
    throttle
    echo ">> launching: $name (log: $LOGDIR/${name}.log)"
    _exec_job "$@" &
}

# ----------------------------------------------------------------------------
# Prerequisites (serial - the parallel builds depend on these)
# ----------------------------------------------------------------------------

prereqs() {
    git submodule init
    git submodule update

    sudo apt-get update
    # intel-mkl (Faiss BLAS backend) prompts a license UI that breaks headless
    # installs; force noninteractive + keep existing config files. openjdk is for
    # the renaissance Java benchmarks, python3.10-venv/-dev for ANN-SoLo.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        libnuma-dev libpmem-dev libaio-dev libssl-dev mpich intel-mkl \
        openjdk-21-jdk python3.10-venv python3.10-dev htop \
        autoconf automake libtool \
        libdb-dev libdb++-dev   # Silo (autotools + Berkeley DB db_cxx.h)

    # Miniconda (headless) + dataVis env for plotting/analysis.  Delegated to the
    # cluster's single source of truth so every provisioning path builds conda the
    # same, verified way (it installs miniconda if absent, repairs base so it can
    # solve, and builds+verifies dataVis -- failing loudly if it can't).  Override
    # the location with ENSURE_CONDA if this ever runs off the instrument-PG0 share.
    local ensure_conda="${ENSURE_CONDA:-/proj/instrument-PG0/ensure_conda.sh}"
    if [[ -r "$ensure_conda" ]]; then
        bash "$ensure_conda"
    else
        echo "ERROR: ensure_conda.sh not found at $ensure_conda (set ENSURE_CONDA)" >&2
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Per-workload build functions
# ----------------------------------------------------------------------------

build_cipp() {
    cd "$ROOT/scripts/cipp-workspace/tools"
    make clean
    make ARCH=haswell -j"$J"
}

build_pebs() {
    cd "$ROOT/scripts/PEBS_page_tracking"
    make -j"$J"
}

build_flexkvs() {
    cd "$ROOT/flexkvs"
    make -j"$J"
}

build_gapbs() {
    cd "$ROOT/gapbs"
    make bench-graphs -j2
    make -j"$J"
}

build_graph500() {
    cd "$ROOT/graph500"
    git checkout master
    cp make-incs/make.inc-gcc make.inc
    #Change makefile gcc version and enable openmp
    sed -i -e 's/^CC = gcc-4.6/CC = gcc/' \
        -e 's/^# \(BUILD_OPENMP = Yes\)/\1/' \
        -e 's/^# \(CFLAGS_OPENMP = -fopenmp\)/\1/' make.inc
    make -j"$J"
}

build_liblinear() {
    cd "$ROOT/liblinear-2.47"
    if [[ ! -f kdd12 ]]; then
        wget https://www.csie.ntu.edu.tw/~cjlin/libsvmtools/datasets/binary/kdd12.xz
        unxz kdd12.xz   # removes the .xz on success
    fi
    make -j"$J"
}

build_merci() {
    cd "$ROOT/MERCI"
    local base="https://pages.cs.wisc.edu/~apoduval/MERCI/data"
    mkdir -p data/4_filtered/amazon_All
    wget -nc -P data/4_filtered/amazon_All \
        "$base/4_filtered/amazon_All/amazon_All_test_filtered.txt" \
        "$base/4_filtered/amazon_All/amazon_All_train_filtered.txt"

    mkdir -p data/5_patoh/amazon_All/partition_2748/
    wget -nc -P data/5_patoh/amazon_All/partition_2748/ \
        "$base/5_patoh/amazon_All/partition_2748/amazon_All_train_filtered.txt.part.2748"

    cd 4_performance_evaluation
    mkdir -p bin
    make -j"$J"
}

build_silo() {
    cd "$ROOT/silo/silo"
    ( cd third-party/lz4 && make library )
    apply_patch ../../patches/silo.patch
    make dbtest -j"$J"
}

build_xsbench() {
    cd "$ROOT/XSBench/openmp-threading"
    make -j"$J"
}

build_npb() {
    cd "$ROOT/NPB-CPP/libs/tbb-2020.1"
    make -j"$J"
    # Make the env-source helper executable (build dir name encodes toolchain).
    chmod +x ./build/*/tbbvars.sh
}

build_minimap2() {
    cd "$ROOT/minimap2"
    git submodule update --init --recursive
}

# SPEC CPU2017: copies a SPEC install locally, writes a clean (non-XRay) -O3 gcc
# config, then builds and stages refrate run dirs for the memory-intensive
# subset used by scripts/workloads/spec.sh. Heavy (~9GB copy + compile). Returns
# 100 (SKIPPED) when disabled or when the source tree is absent.
build_spec() {
    local SPEC_SRC="${SPEC_SRC:-/proj/instrument-PG0/spec}"
    local SPEC_DEST="${SPEC_DEST:-$HOME/spec}"

    if [[ "${BUILD_SPEC:-1}" == "0" ]]; then
        echo "[spec] BUILD_SPEC=0; skipping SPEC build."
        return 100
    fi
    if [[ ! -d "$SPEC_SRC" ]]; then
        echo "[spec] SPEC source not found at $SPEC_SRC; skipping SPEC build."
        echo "[spec] To enable, set SPEC_SRC=/path/to/spec and re-run."
        return 100
    fi

    echo "[spec] installing build toolchain (gcc/g++/gfortran/rsync)"
    # DPkg::Lock::Timeout waits out a concurrent apt (e.g. build_spec2026 running
    # in parallel) instead of failing with apt's exit 100 on a dpkg-lock clash.
    sudo apt-get install -y -o DPkg::Lock::Timeout=600 gcc g++ gfortran rsync

    # Memory-intensive subset that builds cleanly with system gcc/gfortran 11
    # (see docs/spec2017_integration.md). 503.bwaves_r is multi-invocation
    # (4 sub-runs, tracked independently). 510.parest_r is intentionally
    # excluded: its deal.II sources don't compile with gcc 11.
    local SPEC_BENCHMARKS="${SPEC_BENCHMARKS:-505.mcf_r 503.bwaves_r 519.lbm_r 520.omnetpp_r 523.xalancbmk_r 507.cactuBSSN_r 549.fotonik3d_r 554.roms_r 531.deepsjeng_r}"

    echo "[spec] copying $SPEC_SRC -> $SPEC_DEST"
    mkdir -p "$SPEC_DEST"
    # Skip the source tarball, prior (XRay) build artifacts, and results; we rebuild clean.
    rsync -a \
        --exclude 'cpu2017.tar.xz' \
        --exclude 'result/' \
        --exclude '*.log' \
        --exclude 'benchspec/CPU/*/run/' \
        --exclude 'benchspec/CPU/*/build/' \
        --exclude 'benchspec/CPU/*/exe/' \
        "$SPEC_SRC/" "$SPEC_DEST/"

    echo "[spec] writing clean-gcc config (system gcc, -O3 -march=native, no XRay)"
    cp "$SPEC_DEST/config/Example-gcc-linux-x86.cfg" "$SPEC_DEST/config/clean-gcc.cfg"
    sed -i -E 's|(define[[:space:]]+gcc_dir[[:space:]]+).*|\1/usr|' "$SPEC_DEST/config/clean-gcc.cfg"
    sed -i 's|%define label mytest|%define label clean|' "$SPEC_DEST/config/clean-gcc.cfg"
    # gcc 11 defaults to gnu++17, whose 3-arg std::hypot overload breaks
    # omnetpp's Define_Function3(SPEC_HYPOT,2,...) registration at runtime.
    # Build it against pre-C++17.
    cat >> "$SPEC_DEST/config/clean-gcc.cfg" <<'CFG'

520.omnetpp_r:  #lang='CXX'
   CXXPORTABILITY = -std=gnu++14
CFG

    cd "$SPEC_DEST"
    source ./shrc
    echo "[spec] building: $SPEC_BENCHMARKS"
    runcpu --config=clean-gcc --action=build $SPEC_BENCHMARKS
    echo "[spec] staging refrate run dirs: $SPEC_BENCHMARKS"
    # --action=setup only stages run dirs (runs nothing), so runcpu's epilogue
    # exits non-zero with "No output files were found to compare". That's cosmetic
    # here; the run dirs are still staged, so don't let it fail the build.
    runcpu --config=clean-gcc --action=setup --size=ref $SPEC_BENCHMARKS || true
    echo "[spec] done. Run with: ./run.sh -b spec -w mcf -o results/spec_test"
}

# ----------------------------------------------------------------------------
# SPEC CPU2026 (a.k.a. SPEC CPU v8 / cpuv8): installs the suite *from the ISO*
# via SPEC's install.sh, writes a clean (non-XRay) -O3 gcc config, then builds
# and stages refrate run dirs for the memory-intensive subset used by
# scripts/workloads/spec2026.sh. Heavy (~3.8GB extract + compile). Returns
# 100 (SKIPPED) when disabled or when the ISO is absent.
# See docs/spec2026_integration.md.
# ----------------------------------------------------------------------------
build_spec2026() {
    # Delegate to the single source-of-truth provisioner, shared with the sweep's
    # lazy auto-build (scripts/workloads/spec2026.sh). It handles the
    # BUILD_SPEC2026=0 / ISO-absent skips (returns 100 = SKIPPED), the ISO
    # loop-mount + install.sh, the clean-gcc config, and the runcpu build/setup
    # of the memory-intensive subset. Per-benchmark portability stanzas (for
    # system gcc/gfortran 11) get appended to clean-gcc.cfg there as build breaks
    # surface; the CPU2017 analog needed -std=gnu++14 for omnetpp.
    source "$ROOT/scripts/workloads/spec2026_provision.sh"
    provision_spec2026_suite
    local rc=$?
    (( rc == 0 )) && echo "[spec2026] done. Run with: ./run.sh -b spec2026 -w lbm -o results/spec2026_test"
    return $rc
}

# ----------------------------------------------------------------------------
# Summary report
# ----------------------------------------------------------------------------

write_summary() {
    {
        echo "===================================================================="
        echo " Setup Summary  -  $(date '+%F %T')"
        echo " Per-job logs: $LOGDIR"
        echo "===================================================================="
        printf '%-14s %-9s %9s\n' "JOB" "STATUS" "TIME"
        printf '%-14s %-9s %9s\n' "--------------" "---------" "---------"

        local ok=0 fail=0 skip=0
        local -a failed_names=()
        for name in "${JOB_NAMES[@]}"; do
            local sf="$LOGDIR/${name}.status"
            if [[ ! -f "$sf" ]]; then
                printf '%-14s %-9s %9s\n' "$name" "NORESULT" "-"
                fail=$((fail + 1)); failed_names+=("$name"); continue
            fi
            local n rc secs
            IFS='|' read -r n rc secs < "$sf"
            local st
            case "$rc" in
                0)   st="OK";      ok=$((ok + 1)) ;;
                100) st="SKIPPED"; skip=$((skip + 1)) ;;
                *)   st="FAILED";  fail=$((fail + 1)); failed_names+=("$name (rc=$rc)") ;;
            esac
            printf '%-14s %-9s %9s\n' "$name" "$st" "$(fmt_time "$secs")"
        done

        echo "--------------------------------------------------------------------"
        echo "Total: ${#JOB_NAMES[@]}   OK: $ok   FAILED: $fail   SKIPPED: $skip"
        if (( fail > 0 )); then
            echo "Failed: ${failed_names[*]}"
            echo "Inspect logs in $LOGDIR/<job>.log"
        fi
    } | tee "$SUMMARY"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

echo "setup.sh: MAX_PARALLEL=$MAX_PARALLEL  J=$J  LOGDIR=$LOGDIR"
SETUP_START=$(date +%s)

# Prerequisites run serially since the parallel builds depend on them.
echo ">> prerequisites (submodules, apt packages, conda env)"
JOB_NAMES+=("prereqs")
_exec_job prereqs prereqs || echo "WARNING: prereqs reported errors; continuing with builds" >&2

# Concurrent per-workload builds.
run_job cipp       build_cipp
run_job pebs       build_pebs
run_job flexkvs    build_flexkvs
run_job gapbs      build_gapbs
run_job graph500   build_graph500
run_job liblinear  build_liblinear
run_job merci      build_merci
run_job silo       build_silo
run_job xsbench    build_xsbench
run_job npb        build_npb
run_job minimap2   build_minimap2
run_job spec       build_spec
run_job spec2026   build_spec2026

# Wait for all background builds to finish.
wait

SETUP_END=$(date +%s)
echo
write_summary
echo
echo "Total setup time: $(fmt_time $((SETUP_END - SETUP_START)))"

# Exit non-zero if any job failed (skips/oks are fine).
for name in "${JOB_NAMES[@]}"; do
    sf="$LOGDIR/${name}.status"
    [[ -f "$sf" ]] || exit 1
    IFS='|' read -r _ rc _ < "$sf"
    [[ "$rc" == 0 || "$rc" == 100 ]] || exit 1
done
exit 0
