# SPEC CPU2026 Integration — Design Notes

Status: **implemented, built, and smoke-tested.** `./setup.sh` installed CPU2026 from the
ISO and built + staged all 7 subset benchmarks clean (`Build errors: None`). Runtime
derivation verified against the real staged tree, and `lbm`/`cactus`/`zstd` binaries launch
and run with the derived args + staged inputs.

## Build/verification results (this host, system gcc/gfortran 11)

- **All 7 built clean** (~15 min): `lbm fotonik3d roms cactus omnetpp gcc zstd`. exe bases
  as expected — `lbm_r fotonik3d_r roms_r cactus omnetpp_r cc1_r zstd` — all `_base.mytest`.
- **Label is `mytest`, not `clean-m64`:** cpuv8's `Example-gcc-linux-x86.cfg` sets the label
  via an `%ifndef %{label}` guard, so setup.sh's `sed 's/%define label mytest/.../'` is a
  no-op. Harmless: `resolve_spec2026_paths` locates exe/rundir **by glob**, so the label
  suffix doesn't matter. `SPEC2026_LABEL` is consequently vestigial (set, never read).
- **Runtime derivation matches reality** (values that could NOT have been hardcoded, proving
  the live-read design): `lbm` args `900 reference.dat 0 0 200_200_130_ldc.of` (not 2017's
  `3000 …`); `roms` stdin `< roms_benchmark2.in.x` (`varinfo.yaml` excluded); `cactus`
  `ShiftedGaugeWave.par`; multi-invocation counts omnetpp=10 / gcc=3 / zstd=8.
- **Smoke launches** (time-boxed): `lbm`, `cactus`, `zstd` all execute from their staged run
  dirs with the derived args, reading their inputs (`zstd` loads `cld.tar`, 126 MB).

The only layer not yet exercised is a full `run.sh` orchestration (numactl + time +
DAMON/PEBS/numastat), which is the same plumbing CPU2017 `spec` already uses
(`create_workload_wrapper` + `run_workload_standard`); a full refrate run just takes
10+ min per workload.

Kit inspected: `/proj/instrument-PG0/cpu2026-1.0.1.iso` (SPEC CPU2026, a.k.a. **SPEC CPU
v8 / cpuv8**), version 1.0.1, mounted read-only at inspection time.

## What this is (and isn't)

- The ISO is **SPEC CPU2026**, which SPEC also brands **"SPEC CPU v8" (cpuv8)** — same
  product, two names. It is **not** a revision of CPU2017: the benchmark set is entirely
  new (rate IDs `706`–`782`, speed IDs `800`–`881`; new programs), so nothing in
  `spec.sh`'s tables transfers.
- It **shares the toolchain** with CPU2017: the same `runcpu` driver, `install.sh`,
  config/label/toolset system, `Example-gcc-linux-x86.cfg`, and `--size=ref` workflow.
  That is what makes the 2017 integration a valid template.

## Decisions (from grilling session)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Coexistence with `-b spec` (2017) | **New parallel suite.** `scripts/workloads/spec2026.sh` + `setup.sh:build_spec2026`, invoked as `-b spec2026`. `-b spec` stays CPU2017, untouched. Disjoint tables, no version conditionals. |
| 2 | How `build_spec2026` obtains the kit | **Mount the ISO in `setup.sh`.** Loop-mount read-only (sudo — already used for `apt`), run `install.sh -f -d $SPEC2026_DEST`, then unmount. `SPEC2026_ISO` (default `/proj/instrument-PG0/cpu2026-1.0.1.iso`) and `SPEC2026_DEST` (default `$HOME/spec2026`) overridable. Fully automated from a clean checkout. |
| 3 | Benchmark subset (initial) | **Memory-intensive rate core + zstd:** `782.lbm_r 749.fotonik3d_r 765.roms_r 709.cactus_r 710.omnetpp_r 721.gcc_r 777.zstd_r`. Five are direct CPU2017 analogs; `gcc` adds irregular working set, `zstd` large buffers. Non-building ones are pruned empirically (as `parest` was in 2017). |
| 4 | Source of per-benchmark command lines | **Derive at runtime from the staged `control`/`.in` files** (revised — see below). Originally "hardcoded tables like `spec.sh`", but inspecting each benchmark's `object.pm` showed CPU2026's refrate args are **not static**: `invoke()` reads them from a clean per-benchmark `control` (or `lbm.in`) file that `runcpu` stages into the run dir, and the multi-invocation count = number of non-comment lines. So `spec2026.sh` reproduces those tiny `invoke()` rules in bash against the staged files. **Not** the brittle `speccmds.cmd` parse (env dumps, `-b numactl` lines, copy-expansion, gcc's `echo>run.sh`); `control` files are clean (one invocation per line). |
| 5 | Launch model for the timed/instrumented run | **Direct exec from the staged run dir**, same as 2017 (its decision #6). `runcpu` does build + `--action=setup` staging only; the harness `cd`s into `run_base_refrate_<label>.NNNN/` and `exec`s the single binary under `numactl`/`time` with DAMON/PEBS/numastat/HeMem attached. See "Why not runcpu --action=run" below. |
| — | Session scope | **Deliver harness code + docs now; user runs `./setup.sh`.** The full install (~3.8 GB extract) + build of 7 benchmarks + refrate staging is ~45 min+ and may surface portability fixes; not run in-session. |

### Why not `runcpu --action=run` (the instrumentation constraint)

SPEC *does* ship a full harness (`runcpu` + `specinvoke`), and we use it — for **install,
build, and run-dir staging**. We do **not** use it for the timed run because this repo's
purpose is memory instrumentation:

- **DAMON** (`damo record … $pid`) and **numastat** are per-PID and do **not** follow
  exec'd children. `runcpu` launches each benchmark through a layered tree
  (`specinvoke` → `numactl` → binary), leaving no stable PID to attach to.
- The harness interposes a **HeMem memory policy via `LD_PRELOAD`** (`HEMEMPOL`) and owns
  `numactl` binding — `runcpu` exposes no hook for either.
- The repo's output-file scheme (`time.txt`, `bwmon`, `mpstat`, `numastat`, PID file) is
  produced by `create_workload_wrapper` / `run_workload_standard`, not `runcpu`.

Direct-exec of the staged binary is the only model that gives every workload a single,
stable, instrumentable PID — identical rationale to the 2017 integration.

## Kit facts verified during inspection

- Volume id `CPU2026v1.0.1`, system id `LINUX`. Top level: `install.sh` (`-f -d dest`
  for non-interactive install; `-e`/`-u` select toolset), `cshrc`/`shrc`, `Docs/`,
  `install_archives/cpu2026.tar.xz` (3.8 GB), prebuilt toolsets under `tools/bin/`.
- A **prebuilt `linux-x86_64` toolset** ships (`tools/bin/linux-x86_64/tools-linux-x86_64.tar.xz`),
  so `install.sh` will **not** need to build the harness tools from source on this host.
- `config/` example files include `Example-gcc-linux-x86.cfg` (same name as 2017), so the
  clean-gcc config recipe transfers: copy it, set `gcc_dir=/usr`, `label=clean`,
  `-O3 -march=native`, no XRay.

## Rate subset — exe base, invocations, args source

Verified by extracting each benchmark's `Spec/object.pm` and its refrate `control`/`.in`
files from the kit and exercising `spec2026.sh`'s derivation against them.

| `-w` name | SPEC id | exe base | invocations (refrate) | args source (per `object.pm`) | 2017 analog |
|-----------|---------|----------|-----------------------|-------------------------------|-------------|
| `fotonik3d` | 749.fotonik3d_r | `fotonik3d_r` | 1 | none | 549.fotonik3d_r |
| `lbm`       | 782.lbm_r       | `lbm_r`       | 1 | first line of `lbm.in` | 519.lbm_r |
| `cactus`    | 709.cactus_r    | **`cactus`**  | 1 | first line of `control` (`ShiftedGaugeWave.par`) | 507.cactuBSSN_r |
| `roms`      | 765.roms_r      | `roms_r`      | 1+ | stdin `< <name>.in.x` per input (excl. `varinfo.yaml`) | 554.roms_r |
| `omnetpp`   | 710.omnetpp_r   | `omnetpp_r`   | **10** | `-f <cfg> -c <name>` per `control` line | 520.omnetpp_r |
| `gcc`       | 721.gcc_r       | **`cc1_r`**   | **3** | `<src> <opts> -o <tag>.s` per `control` line | 502.gcc_r |
| `zstd`      | 777.zstd_r      | **`zstd`**    | **8** | each `control` line = full arg vector | (new) |

Note the exe base is **not** always `<name>_r` (cactus→`cactus`, gcc→`cc1_r`, zstd→`zstd`),
so `SPEC2026_EXE` carries the real `@base_exe` names. `omnetpp`/`gcc`/`zstd` are
multi-invocation; the harness emits ordinal labels `1..N` (→ files `spec2026_<w>_<n>_*`)
and tracks each independently via the generic mechanism
(`docs/adr/0001-multi-invocation-workloads.md`). Invocation counts above are read live
from the staged `control` files, so they self-adjust if a kit revision changes them.

## Implementation sketch

1. **`setup.sh` — `build_spec2026`** (runs by default when `$SPEC2026_ISO` exists;
   force-skip with `BUILD_SPEC2026=0`; returns SKIPPED when the ISO is absent):
   - `sudo apt-get install -y gcc g++ gfortran` (Fortran needed for roms/fotonik3d/cactus).
   - Loop-mount `$SPEC2026_ISO` read-only → run `<mnt>/install.sh -f -d $SPEC2026_DEST` →
     unmount (trap-guarded so the mount is always released).
   - Write `config/clean-gcc.cfg` from `Example-gcc-linux-x86.cfg`: `gcc_dir=/usr`,
     `label=clean`, `-O3 -march=native`, no XRay; add per-benchmark portability stanzas
     as build breaks surface.
   - `source shrc && runcpu --config=clean-gcc --action=build <subset>`.
   - `runcpu --config=clean-gcc --action=setup --size=ref <subset>` to stage run dirs
     (tolerate its cosmetic non-zero epilogue, as 2017 does).

2. **`scripts/workloads/spec2026.sh`** (implemented) — mirrors `spec.sh` in shape:
   `config_spec2026` (`SPEC2026_PATH`, `SPEC2026_LABEL=clean-m64`, `WORK_SIZE=refrate`),
   `resolve_spec2026_paths` (locates exe + refrate rundir **by glob**, tolerant of the
   exact label suffix), `build_spec2026` (validate exe + staged rundir),
   `invocations_spec2026`, `run_spec2026`. The novel piece is
   **`spec2026_invocations <workload> <rundir>`**, which reproduces each benchmark's
   `object.pm` `invoke()` against the staged `control`/`.in` files and echoes one arg
   string per invocation (a leading `< file` is a stdin redirect for `roms`, written
   verbatim into the wrapper's `exec`). `invocations_spec2026` counts those lines → ordinal
   labels `1..N` (or none); `run_spec2026` selects the current label's line, then
   `create_workload_wrapper … "$rundir"` + `run_workload_standard "--cpunodebind=0 -p 0"`.

3. **Docs**: this file; a `spec2026` row in `CLAUDE.md`'s workload index; glossary entries
   in `CONTEXT.md` distinguishing `-b spec` (2017) from `-b spec2026` (2026/cpuv8).

## Verified without a full build

`spec2026_invocations` needs only the small `control`/`.in` files (not compiled binaries),
so the derivation was validated in-session against the **real** kit control files for all
seven workloads: correct exe bases, `roms` stdin redirect with `varinfo.yaml` excluded,
and invocation counts omnetpp=10 / gcc=3 / zstd=8. `build_spec2026` validation, per-label
selection, and wrapper generation (cd + stdin redirect) all check out. `bash -n` clean.

## Open items (resolved when the user runs `./setup.sh`, not design)

- Whether every subset member compiles clean with system gcc/gfortran (the 2017 analog
  needed `-std=gnu++14` for omnetpp; append per-benchmark `CXXPORTABILITY`/portability
  stanzas to `clean-gcc.cfg` as breaks surface, and prune any that can't build).
- The exact build `LABEL` suffix cpuv8's clean-gcc config emits — the resolver globs for
  exe/rundir so a differing suffix is tolerated, but confirm `SPEC2026_LABEL` if anything
  keys on it.
- The real refrate `lbm.in` contents and `roms` `.in.x` input name(s) — read live at run
  time, so no code change needed; listed only so a reviewer knows they were not hardcoded.
