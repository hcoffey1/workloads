#!/bin/bash
# ==============================================================================
# spec2026_provision.sh — install + build SPEC CPU2026 (cpuv8) from the ISO.
# ==============================================================================
# Single source of truth for provisioning the SPEC CPU2026 refrate subset.
# Sourced by BOTH:
#   * setup.sh's build_spec2026 (explicit provisioning path), and
#   * scripts/workloads/spec2026.sh's build_spec2026 (LAZY auto-build: the first
#     dispatched sweep job that lands on a machine with no built suite calls this
#     to bootstrap it, so no separate fleet-wide build step is needed).
#
# provision_spec2026_suite() is idempotent (runcpu rebuilds only what's missing)
# and host-serialized (flock) so it is safe to call from a job. It contains all
# cwd/env changes in a subshell so it never perturbs a caller mid-run.
#
# Env overrides:
#   SPEC2026_ISO         ISO image   (default /proj/instrument-PG0/cpu2026-1.0.1.iso)
#   SPEC2026_DEST        install dir  (default $HOME/spec2026)
#   SPEC2026_BENCHMARKS  subset ids   (default: the 7-workload memory subset)
#   BUILD_SPEC2026=0     skip (returns 100 = SKIPPED)
#
# Returns: 0 on success, 100 when disabled or the ISO is absent (SKIPPED),
# non-zero on a real failure.
# ==============================================================================

provision_spec2026_suite() {
    local iso="${SPEC2026_ISO:-/proj/instrument-PG0/cpu2026-1.0.1.iso}"
    local dest="${SPEC2026_DEST:-$HOME/spec2026}"
    # Memory-intensive rate subset (see docs/spec2026_integration.md). 721.gcc_r
    # is multi-invocation. Prune non-building members here empirically, as
    # 510.parest_r was for CPU2017.
    local benches="${SPEC2026_BENCHMARKS:-782.lbm_r 749.fotonik3d_r 765.roms_r 709.cactus_r 710.omnetpp_r 721.gcc_r 777.zstd_r}"

    if [[ "${BUILD_SPEC2026:-1}" == "0" ]]; then
        echo "[spec2026] BUILD_SPEC2026=0; skipping SPEC CPU2026 build."
        return 100
    fi
    if [[ ! -f "$iso" ]]; then
        echo "[spec2026] ISO not found at $iso; cannot build SPEC CPU2026."
        echo "[spec2026] To enable, set SPEC2026_ISO=/path/to/cpu2026.iso and re-run."
        return 100
    fi

    mkdir -p "$dest"
    # Serialize provisioning per host so a second caller (e.g. build called once
    # per iteration, or a retry) never installs concurrently; the loser blocks,
    # then re-runs runcpu, which no-ops if the suite is already built.
    exec 9>"$dest/.provision.lock"
    flock 9

    # Toolchain (Fortran needed for roms/fotonik3d/cactus). Install only if
    # missing; DPkg::Lock::Timeout waits out a concurrent apt instead of failing
    # with apt's exit 100 on a dpkg-lock clash.
    if ! command -v gcc >/dev/null || ! command -v g++ >/dev/null || ! command -v gfortran >/dev/null; then
        echo "[spec2026] installing build toolchain (gcc/g++/gfortran)"
        sudo apt-get install -y -o DPkg::Lock::Timeout=600 gcc g++ gfortran || { flock -u 9; exec 9>&-; return 1; }
    else
        echo "[spec2026] build toolchain (gcc/g++/gfortran) already present"
    fi

    # Loop-mount the ISO read-only; always release it, even on failure.
    local mnt; mnt="$(mktemp -d)"
    echo "[spec2026] mounting $iso -> $mnt"
    if ! sudo mount -o loop,ro "$iso" "$mnt"; then
        echo "[spec2026] ERROR: could not mount $iso"
        rmdir "$mnt" 2>/dev/null; flock -u 9; exec 9>&-; return 1
    fi

    # All cwd/env mutation (cd $dest, source shrc which rewrites PATH + SPEC vars,
    # runcpu) stays inside this subshell so the calling sweep job's environment is
    # untouched. install.sh is inside too since it may cd.
    local rc=0
    (
        set -e
        echo "[spec2026] installing to $dest"
        # -f: non-interactive; -d: destination. A prebuilt linux-x86_64 toolset
        # ships on the ISO, so no source build of the harness tools is needed.
        "$mnt/install.sh" -f -d "$dest"

        echo "[spec2026] writing clean-gcc config (system gcc, -O3 -march=native, no XRay)"
        cp "$dest/config/Example-gcc-linux-x86.cfg" "$dest/config/clean-gcc.cfg"
        sed -i -E 's|(define[[:space:]]+gcc_dir[[:space:]]+).*|\1/usr|' "$dest/config/clean-gcc.cfg"
        sed -i 's|%define label mytest|%define label clean|' "$dest/config/clean-gcc.cfg"

        cd "$dest"
        source ./shrc
        echo "[spec2026] building: $benches"
        runcpu --config=clean-gcc --action=build $benches
        echo "[spec2026] staging refrate run dirs: $benches"
        # --action=setup stages run dirs only; runcpu's compare epilogue then
        # exits non-zero ("No output files were found"). Cosmetic; don't fail.
        runcpu --config=clean-gcc --action=setup --size=ref $benches || true
    ) || rc=$?

    sudo umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null
    flock -u 9; exec 9>&-

    if (( rc != 0 )); then
        echo "[spec2026] provision FAILED (rc=$rc)"
        return "$rc"
    fi
    echo "[spec2026] provision complete -> $dest"
    return 0
}
