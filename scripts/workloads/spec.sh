#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# ==============================================================================
# SPEC CPU2017 integration
# ==============================================================================
# Runs a single-invocation, memory-intensive subset of SPEC CPU2017 at the
# 'refrate' input size.  The clean (non-XRay) -O3 gcc build and the staged run
# directories are produced by setup.sh's build_spec step; this script only
# locates the prebuilt binary + staged run dir and launches it under the
# harness so DAMON/PEBS/numastat attach to a single tracked PID.
#
# Layout produced by setup.sh:
#   $SPEC_PATH/benchspec/CPU/<id>/exe/<exebase>_base.<LABEL>
#   $SPEC_PATH/benchspec/CPU/<id>/run/run_base_refrate_<LABEL>.NNNN/
#
# Override the install location with: SPEC_PATH=/path/to/spec ./run.sh -b spec ...

# Short workload name -> SPEC benchmark id
declare -gA SPEC_ID=(
    [mcf]=505.mcf_r
    [lbm]=519.lbm_r
    [omnetpp]=520.omnetpp_r
    [xalancbmk]=523.xalancbmk_r
    [cactuBSSN]=507.cactuBSSN_r
    [parest]=510.parest_r
    [fotonik3d]=549.fotonik3d_r
    [roms]=554.roms_r
    [deepsjeng]=531.deepsjeng_r
    [leela]=541.leela_r
    [imagick]=538.imagick_r
)

# Short workload name -> built executable base name (before _base.<LABEL>)
declare -gA SPEC_EXE=(
    [mcf]=mcf_r
    [lbm]=lbm_r
    [omnetpp]=omnetpp_r
    [xalancbmk]=cpuxalan_r
    [cactuBSSN]=cactusBSSN_r
    [parest]=parest_r
    [fotonik3d]=fotonik3d_r
    [roms]=roms_r
    [deepsjeng]=deepsjeng_r
    [leela]=leela_r
    [imagick]=imagick_r
)

# Short workload name -> refrate argument string (run from inside the run dir).
# 'roms' reads its input from stdin, hence the embedded redirect.
declare -gA SPEC_ARGS=(
    [mcf]="inp.in"
    [lbm]="3000 reference.dat 0 0 100_100_130_ldc.of"
    [omnetpp]="-c General -r 0"
    [xalancbmk]="-v t5.xml xalanc.xsl"
    [cactuBSSN]="spec_ref.par"
    [parest]="ref.prm"
    [fotonik3d]=""
    [roms]="< ocean_benchmark2.in.x"
    [deepsjeng]="ref.txt"
    [leela]="ref.sgf"
    [imagick]="-limit disk 0 refrate_input.tga -resize 817% -rotate -2.76 -shave 540x375 -alpha remove -auto-level -contrast-stretch 1x1% -colorspace Lab -channel R -equalize +channel -colorspace sRGB -define histogram:unique-colors=false -adaptive-blur 0x5 -despeckle -auto-gamma -adaptive-sharpen 55 -enhance -brightness-contrast 10x10 -resize 30% refrate_output.tga"
)

config_spec(){
    # Local SPEC install (copied + clean-built by setup.sh). Overridable via env.
    : "${SPEC_PATH:=$HOME/spec}"
    # Build label set in config/clean-gcc.cfg (label = clean, bits = 64).
    : "${SPEC_LABEL:=clean-m64}"
    WORK_SIZE="refrate"
}

# Resolve <id>, <exe path>, <run dir> for a short workload name into globals:
#   spec_id, spec_exe, spec_rundir
resolve_spec_paths(){
    local workload="$1"

    spec_id="${SPEC_ID[$workload]:-}"
    if [[ -z "$spec_id" ]]; then
        echo "ERROR: Unsupported SPEC workload '$workload'"
        echo "Supported: ${!SPEC_ID[*]}"
        return 1
    fi

    local bench_dir="$SPEC_PATH/benchspec/CPU/$spec_id"
    spec_exe="$bench_dir/exe/${SPEC_EXE[$workload]}_base.${SPEC_LABEL}"

    # Pick the first staged refrate run directory.
    spec_rundir=$(ls -d "$bench_dir/run/run_base_refrate_${SPEC_LABEL}".* 2>/dev/null | head -1)
    return 0
}

build_spec(){
    local workload="$1"
    resolve_spec_paths "$workload" || exit 1

    if [[ ! -x "$spec_exe" ]]; then
        echo "ERROR: SPEC binary not found/executable: $spec_exe"
        echo "Build SPEC first: run ./setup.sh (build_spec step)."
        exit 1
    fi
    if [[ -z "$spec_rundir" || ! -d "$spec_rundir" ]]; then
        echo "ERROR: No staged refrate run dir for $spec_id under $SPEC_PATH"
        echo "Stage it first: runcpu --config=clean-gcc --action=setup --size=ref $spec_id"
        exit 1
    fi
    echo "SPEC $workload -> $spec_id"
    echo "  exe:    $spec_exe"
    echo "  rundir: $spec_rundir"
}

run_spec(){
    local workload="$1"
    resolve_spec_paths "$workload" || exit 1

    generate_workload_filenames "$workload"

    echo "Running SPEC workload: $workload ($spec_id)"

    # Build a wrapper that cd's into the staged run dir before exec'ing the
    # binary so it finds its inputs and writes outputs locally.
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$spec_exe" \
        "${SPEC_ARGS[$workload]}" "" "$spec_rundir"

    run_workload_standard "--cpunodebind=0 -p 0"
}

run_strace_spec(){
    return
}

clean_spec(){
    return
}
