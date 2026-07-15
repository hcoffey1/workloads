#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# ==============================================================================
# SPEC CPU2026 integration  (a.k.a. SPEC CPU v8 / cpuv8)
# ==============================================================================
# Runs a memory-intensive rate subset of SPEC CPU2026 at the 'refrate' input
# size. This is a SEPARATE suite from `-b spec` (CPU2017); the benchmark set is
# entirely disjoint. The clean (non-XRay) -O3 gcc build and the staged run
# directories are produced by setup.sh's build_spec2026 step (installed from the
# ISO); this script only locates the prebuilt binary + staged run dir and
# launches it under the harness so DAMON/PEBS/numastat attach to a single
# tracked PID (the direct-exec launch model; see docs/spec2026_integration.md).
#
# Layout produced by setup.sh:
#   $SPEC2026_PATH/benchspec/CPU/<id>/exe/<exebase>_base.<LABEL>
#   $SPEC2026_PATH/benchspec/CPU/<id>/run/run_base_refrate_<LABEL>.NNNN/
#
# Override the install location with:
#   SPEC2026_PATH=/path/to/spec2026 ./run.sh -b spec2026 ...
#
# Command lines are NOT hardcoded: unlike CPU2017, CPU2026's refrate args are
# data-driven, read from a clean per-benchmark `control` (or `lbm.in`) file that
# runcpu stages into the run dir. spec2026_invocations() reproduces each
# benchmark's Spec/object.pm invoke() logic against those files at run time, so
# multi-invocation counts (omnetpp/gcc/zstd) follow the staged control files
# automatically. See docs/spec2026_integration.md.

# Short workload name -> SPEC CPU2026 benchmark id
declare -gA SPEC2026_ID=(
    [lbm]=782.lbm_r
    [fotonik3d]=749.fotonik3d_r
    [roms]=765.roms_r
    [cactus]=709.cactus_r
    [omnetpp]=710.omnetpp_r
    [gcc]=721.gcc_r
    [zstd]=777.zstd_r
)

# Short workload name -> built executable base name (before _base.<LABEL>).
# These are the @base_exe values from each benchmark's Spec/object.pm; note they
# are NOT always "<name>_r" (cactus->cactus, gcc->cc1_r, zstd->zstd).
declare -gA SPEC2026_EXE=(
    [lbm]=lbm_r
    [fotonik3d]=fotonik3d_r
    [roms]=roms_r
    [cactus]=cactus
    [omnetpp]=omnetpp_r
    [gcc]=cc1_r
    [zstd]=zstd
)

config_spec2026(){
    # Local SPEC CPU2026 install (installed + clean-built by setup.sh).
    # Overridable via env; defaults track setup.sh's SPEC2026_DEST.
    : "${SPEC2026_PATH:=${SPEC2026_DEST:-$HOME/spec2026}}"
    # Build label from config/clean-gcc.cfg (label = clean, bits = 64).
    : "${SPEC2026_LABEL:=clean-m64}"
    WORK_SIZE="refrate"
}

# Resolve <id>, <exe path>, <run dir> for a short workload name into globals:
#   spec_id, spec_exe, spec_rundir
# The exe and run dir are located by glob (not by exact LABEL) so the resolver
# tolerates a differing label suffix from what setup.sh's clean-gcc config emits;
# a clean install builds exactly one config, so the first match is unambiguous.
resolve_spec2026_paths(){
    local workload="$1"

    spec_id="${SPEC2026_ID[$workload]:-}"
    if [[ -z "$spec_id" ]]; then
        echo "ERROR: Unsupported SPEC CPU2026 workload '$workload'"
        echo "Supported: ${!SPEC2026_ID[*]}"
        return 1
    fi

    local bench_dir="$SPEC2026_PATH/benchspec/CPU/$spec_id"
    spec_exe=$(ls "$bench_dir/exe/${SPEC2026_EXE[$workload]}_base."* 2>/dev/null | head -1)

    # Pick the first staged refrate run directory.
    spec_rundir=$(ls -d "$bench_dir/run/run_base_refrate_"*/ 2>/dev/null | head -1)
    spec_rundir="${spec_rundir%/}"
    return 0
}

# Echo, one per line and in invocation order, the argument string for each
# refrate invocation of $1, reproducing that benchmark's Spec/object.pm invoke()
# logic against the clean control/.in inputs staged in $2 (the run dir). A
# single-invocation benchmark echoes exactly one line (possibly empty). A
# leading "< file" is a stdin redirect embedded verbatim into the wrapper's
# `exec` line (create_workload_wrapper writes `exec "$bin" $args` literally).
spec2026_invocations(){
    local workload="$1" rundir="$2"
    case "$workload" in
        fotonik3d)
            # No arguments; reads its inputs from the run dir.
            echo ""
            ;;
        lbm)
            # object.pm: args = first line of lbm.in, whitespace-split.
            head -n1 "$rundir/lbm.in"
            ;;
        cactus)
            # object.pm: args = first line of control (a .par file name).
            head -n1 "$rundir/control"
            ;;
        roms)
            # object.pm: one invocation per *.in.x input (varinfo.yaml excluded
            # by the glob), each reading its grid from stdin.
            local f
            for f in "$rundir"/*.in.x; do
                [[ -e "$f" ]] || continue
                echo "< $(basename "$f")"
            done
            ;;
        omnetpp)
            # object.pm: each non-comment control line "<cfg> <name> [runno]"
            # -> "-f <cfg> -c <name>" (run number ignored).
            grep -vE '^[[:space:]]*(#|$)' "$rundir/control" | while read -r cfg name _rest; do
                echo "-f $cfg -c $name"
            done
            ;;
        gcc)
            # object.pm: each non-comment control line "<src> <opts...>"
            # -> "<src> <opts> -o <tag>.s", where tag is a filename-safe form of
            # the source+opts. We don't run SPEC's output compare, so the tag
            # only needs to be a valid, unique output filename.
            grep -vE '^[[:space:]]*(#|$)' "$rundir/control" | while read -r src opts; do
                local tag="${src}.opts${opts}"
                tag="${tag//[![:alnum:].]/_}"
                echo "$src $opts -o ${tag}.s"
            done
            ;;
        zstd)
            # object.pm: each non-comment control line is already the full arg
            # vector (e.g. "-b3 -e3 --verbose -i40 cld.tar").
            grep -vE '^[[:space:]]*(#|$)' "$rundir/control"
            ;;
        *)
            echo "ERROR: no invocation rule for spec2026 workload '$workload'" >&2
            return 1
            ;;
    esac
}

build_spec2026(){
    local workload="$1"
    resolve_spec2026_paths "$workload" || exit 1

    # Lazy auto-provision: if this host has no built binary / staged refrate run
    # dir for the subset yet, install + build SPEC CPU2026 from the ISO now. A
    # dispatched sweep job thus self-bootstraps the suite the first time it lands
    # on a machine -- no separate fleet-wide build step. provision_spec2026_suite
    # builds the whole subset once (so later spec2026 jobs on this host skip), is
    # idempotent, and is host-serialized. Disable with BUILD_SPEC2026=0.
    if [[ -z "$spec_exe" || ! -x "$spec_exe" || -z "$spec_rundir" || ! -d "$spec_rundir" ]]; then
        echo "SPEC CPU2026 not built on $(hostname -s) for '$workload' ($spec_id); auto-provisioning suite (first spec2026 job on this machine)..."
        source "$CUR_PATH/scripts/workloads/spec2026_provision.sh"
        if ! provision_spec2026_suite; then
            echo "ERROR: SPEC CPU2026 auto-provision failed for '$workload' ($spec_id)."
            echo "Provision manually with ./setup.sh (build_spec2026) or set SPEC2026_ISO."
            exit 1
        fi
        # Re-resolve now that the suite is installed + staged.
        resolve_spec2026_paths "$workload" || exit 1
    fi

    if [[ -z "$spec_exe" || ! -x "$spec_exe" ]]; then
        echo "ERROR: SPEC CPU2026 binary still not found/executable for '$workload' ($spec_id) after provision."
        exit 1
    fi
    if [[ -z "$spec_rundir" || ! -d "$spec_rundir" ]]; then
        echo "ERROR: No staged refrate run dir for $spec_id under $SPEC2026_PATH after provision."
        exit 1
    fi
    echo "SPEC CPU2026 $workload -> $spec_id"
    echo "  exe:    $spec_exe"
    echo "  rundir: $spec_rundir"
}

# Echo the sub-invocation labels for a SPEC CPU2026 workload (empty for single-
# invocation benchmarks). Labels are bare ordinals (1..N) so per-sub-run output
# files read as spec2026_<workload>_<n>_* (the filename already carries the
# workload name). run.sh's get_invocation_labels calls this to drive its
# per-invocation attach/track/detach loop.
invocations_spec2026(){
    local workload="$1"
    resolve_spec2026_paths "$workload" >/dev/null 2>&1 || return 0
    [[ -n "$spec_rundir" && -d "$spec_rundir" ]] || return 0

    local n
    n=$(spec2026_invocations "$workload" "$spec_rundir" 2>/dev/null | wc -l)
    # >1 real invocation => emit ordinal labels; single => none (unlabelled run).
    if (( n > 1 )); then
        seq 1 "$n" | tr '\n' ' '
    fi
}

run_spec2026(){
    local workload="$1"
    resolve_spec2026_paths "$workload" || exit 1

    # One staged rundir holds the binary + every invocation's inputs.
    # generate_workload_filenames picks up CURRENT_INVOCATION_LABEL (set by
    # run.sh) automatically, so each sub-run gets its own output files.
    generate_workload_filenames "$workload"

    # Reproduce object.pm's invoke() against the staged control/.in files, then
    # select the invocation for the current sub-run. The label is an ordinal
    # (1..N); single-invocation runs have no label and default to invocation 1.
    local -a inv
    mapfile -t inv < <(spec2026_invocations "$workload" "$spec_rundir")
    local idx="${CURRENT_INVOCATION_LABEL:-1}"
    local args="${inv[$((idx-1))]}"

    echo "Running SPEC CPU2026 workload: $workload ($spec_id)${CURRENT_INVOCATION_LABEL:+ [invocation $CURRENT_INVOCATION_LABEL/${#inv[@]}]}"

    # Build a wrapper that cd's into the staged run dir before exec'ing the
    # binary so it finds its inputs and writes outputs locally. A leading
    # "< file" in $args (roms) is written verbatim as a stdin redirect.
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$spec_exe" \
        "$args" "" "$spec_rundir"

    run_workload_standard "--cpunodebind=0 -p 0"
}

run_strace_spec2026(){
    return
}

clean_spec2026(){
    return
}
