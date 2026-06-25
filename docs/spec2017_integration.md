# SPEC CPU2017 Integration — Design Notes

Status: **implemented and smoke-tested.**
Source install inspected: `/proj/instrument-PG0/spec/` (SPEC CPU2017, config `hc.cfg`).

## Verification (gcc 11.4, this host)

- Clean build of the subset succeeds for **7/8**: `mcf, lbm, omnetpp, xalancbmk,
  cactuBSSN, fotonik3d, roms`. `parest` fails to compile (see note below).
- End-to-end harness run of `mcf` at refrate:
  `./run.sh -b spec -w mcf -o results/spec_smoke` → exit 0,
  wall 13:47, max RSS ~610 MB, output `10630439290` **matches** SPEC's reference
  `data/refrate/output/mcf.out`. `time.txt`, `stdout`, and `numastat` all captured.
- All 7 build and run end-to-end at refrate (exit 0). Measured peak RSS
  (`Maximum resident set size` from `_time.txt`) on this host:

  | workload  | peak RSS | wall |
  |-----------|---------:|-----:|
  | mcf       |  609 MB  | 13:47 |
  | lbm       |  410 MB  |  6:05 |
  | omnetpp   |  242 MB  | 14:40 |
  | xalancbmk |  480 MB  |  9:16 |
  | cactuBSSN |  789 MB  |  7:07 |
  | fotonik3d |  848 MB  |  9:31 |
  | roms      |  842 MB  |  9:22 |

- **omnetpp build fix:** gcc 11 defaults to `gnu++17`, whose 3-arg `std::hypot`
  overload (exposed via `<math.h>`) makes omnetpp's
  `Define_Function3(SPEC_HYPOT, 2, ...)` resolve to the 3-arg `cMathFunction`
  constructor and abort at startup ("wrong number of arguments 2, should be 3").
  `setup.sh` builds omnetpp with `CXXPORTABILITY = -std=gnu++14` to drop the
  C++17 overload. (Raw runs are preserved under `results/spec_rss/`.)

## Context / what already exists

- `run.sh` dispatches **by suite**: it sources `scripts/workloads/<suite>.sh` and calls
  `config_<suite>` → `build_<suite>` → `run_<suite>` → `clean_<suite>`, passing the
  `-w` workload name as an argument. So `scripts/workloads/spec.sh` is the single
  integration point. A `spec.sh` already exists but is **mismatched** for this machine:
  - it points at `/mydata/spec/cpu2017/` (doesn't exist here),
  - uses config `try1` and build dir `build_base_hayden-mytest-m64.0000`,
  - lists `cactus` — which isn't built in the available install.
- The real install at `/proj/instrument-PG0/spec/` was built with `hc.cfg`:
  - label `mytest-m64` → exe `*_base.mytest-m64`, build dir `build_base_mytest-m64.0000`,
  - **XRay-instrumented**: `-fxray-instrument -fno-inline -Xclang -disable-O0-optnone`,
  - only **`test`-size** run dirs are staged (`run_base_test_mytest-m64.*`); the staged
    `speccmds.cmd` files contain absolute paths to the *original* build machine
    (`/media/hdd0/research/spec`), so run dirs must be re-staged locally.
- 18 benchmarks have built exes (C/C++ only): perlbench, gcc, mcf, omnetpp, xalancbmk,
  x264, deepsjeng, leela, xz (rate + speed). No FP/Fortran benchmarks built.

## Decisions (from grilling session)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Install location | Copy `/proj/instrument-PG0/spec` to a **local** path (default `~/spec`, `/proj` is storage-limited). `SPEC_PATH`/`SPEC_DEST` overridable. |
| 2 | Build flavor | **Clean `-O3` gcc build, no XRay.** Do not reuse the instrumented binaries. |
| 3 | Toolchain | **System gcc/g++** (base on SPEC's `Example-gcc-linux-x86.cfg`, `-O3 -march=native`). Handles Fortran if FP set expands later. |
| 4 | Benchmark set | **Curated memory-intensive subset.** |
| 5 | Input size | **ref** (refrate). Run dirs staged via `runcpu --action=setup`. |
| 6 | Launch model | **Direct binary from staged run dir.** `cd` into run dir, exec binary directly so one PID is tracked under `numactl`/`time`. Not via `runcpu --action=run`. |
| 7 | Multi-command benchmarks | **Supported via a generic multi-invocation mechanism** (since `bwaves`). A workload declares its sub-invocations (`invocations_<suite>`); `run.sh` loops attach→track→detach once per sub-invocation, each fully and independently tracked (separate numastat/DAMON/PEBS captures + output files). Workloads that declare nothing run exactly once, unlabelled — byte-for-byte identical to before. See decision 9 and `docs/adr/0001-multi-invocation-workloads.md`. |
| 8 | setup.sh | **Automate** copy + clean build + ref run-dir staging in a `build_spec` step. |
| 9 | Multi-invocation instrumentation granularity | **Per-invocation capture cycle** (one numastat/DAMON/PEBS start+stop per sub-run) rather than one capture spanning all sub-runs. Gives clean per-solve alignment; `sys_init`/`sys_cleanup` (cache drop, RSS settling) still run once per workload to preserve timing semantics. `bwaves` is the first user: 4 sub-runs → `spec_bwaves_1`..`spec_bwaves_4`. |

### Why single-invocation only (instrumentation constraint)

- **PEBS** is system-wide (`pebs_periodic_reads.x` takes no PID) — captures everything.
- **DAMON** (`damo record … $pid`) and **numastat** are **per-PID and do not follow
  exec'd children**. A multi-command shell wrapper would leave DAMON/numastat watching
  the near-empty wrapper shell, not the benchmark. Restricting to single-invocation
  benchmarks lets the existing `exec`-the-binary model give every workload a stable,
  meaningful tracked PID.

## `-w` subset (ref, memory-intensive)

All single-invocation ones are a single binary invocation at refrate, so the wrapper can
`cd` into the run dir and `exec` the binary (DAMON/PEBS/numastat all attach cleanly).
`bwaves` is **multi-invocation** (4 sub-runs); the harness loops the attach/track/detach
cycle once per sub-run (decision 9), each with its own tracked PID.

| `-w` name | SPEC id | lang | character |
|-----------|---------|------|-----------|
| `mcf`       | 505.mcf_r       | C   | pointer-chasing, irregular, cache-unfriendly |
| `bwaves`    | 503.bwaves_r    | Fortran | blast-wave CFD, **4 sub-runs**, very high streaming bandwidth |
| `lbm`       | 519.lbm_r       | C   | streaming lattice-Boltzmann, very high bandwidth |
| `omnetpp`   | 520.omnetpp_r   | C++ | discrete-event sim, large irregular footprint |
| `xalancbmk` | 523.xalancbmk_r | C++ | XML→XSLT, large heap, pointer-heavy |
| `cactuBSSN` | 507.cactuBSSN_r | C++/C/Fortran | numerical relativity, large grid, high bandwidth |
| `fotonik3d` | 549.fotonik3d_r | Fortran | FDTD electromagnetics, high bandwidth |
| `roms`      | 554.roms_r      | Fortran | ocean model, large, reads input from **stdin** |

`510.parest_r` was in the intended subset but is **excluded**: its bundled deal.II
sources do not compile with gcc 11 (ambiguous template specialization of
`back_interpolate<3>` — a hard C++ conformance error, not fixable with
`-fpermissive`). It remains in `spec.sh`'s tables, so if it is ever ported/built it
will run; it is just not in the default `setup.sh` build list.

Optional smaller/compute-bound C/C++ ones (lower memory intensity): `deepsjeng` (531) —
now in the default `setup.sh` build set; `leela` (541), `imagick` (538) — in `spec.sh`'s
tables but not built by default.

Reference invocation forms (from `Spec/object.pm`; args shown for refrate):
- `mcf_r inp.in`
- `lbm_r 3000 reference.dat 0 0 100_100_130_ldc.of`
- `omnetpp_r -c General -r 0`
- `cpuxalan_r -v t5.xml xalanc.xsl`
- `cactusBSSN_r spec_ref.par`
- `parest_r ref.prm`
- `fotonik3d_r` (reads files in run dir)
- `roms_r < ocean_benchmark2.in.x`  ← stdin redirect; embed `< file` in the wrapper exec line

## Multi-invocation benchmarks

These run **several binary invocations** per ref run. The generic multi-invocation
mechanism (decision 7/9) now supports this class: a workload declares its sub-invocations
and each is tracked independently. `503.bwaves_r` is integrated (see the subset table
above). The rest below are **not yet integrated** — they remain candidates; each just
needs a `SPEC_SUBRUNS` entry plus per-label `SPEC_ARGS`.

### 503.bwaves_r — 4 invocations (**integrated**)
Blast-wave CFD (Fortran). Same binary run **4 times** over 4 grids
(`bwaves_1`..`bwaves_4`), each `bwaves_r bwaves_N < bwaves_N.in`, driven by SPEC's
`control` file. Each invocation is an independent, long, high-bandwidth solve; all four
are memory-twins (~250k-cell grids) differing only in aspect ratio and timestep count.
Run as four independently-tracked sub-runs (`spec_bwaves_1`..`spec_bwaves_4`).

### 500.perlbench_r — 3 invocations
Perl interpreter benchmark; each invocation runs a different Perl workload script:
1. `checkspam.pl 2500 5 25 11 150 1 1 1 1` — SpamAssassin-style mail scoring (regex/string heavy).
2. `diffmail.pl 4 800 10 17 19 300` — generates/diffs synthetic mailboxes.
3. `splitmail.pl 6400 12 26 16 100 0` — splits a large mail spool.
Memory: moderate; lots of small-object allocation/GC churn in the Perl interpreter.

### 502.gcc_r — 9 invocations
The GCC 4.x compiler compiling 9 preprocessed C sources, each to assembly (`-o X.s`)
with different optimization/inline-limit flags, e.g.
`gcc-pp.c -O3 -finline-limit=0`, `gcc-pp.c -O2 -finline-limit=…`, `ref32.c -O5`,
`ref32.c -O3 -fselective-scheduling …`, `gcc-smaller.c -O3 …`, etc.
Memory: large, irregular working set (compiler IR/graphs); a classic memory-intensive int benchmark.

### 525.x264_r — 3 invocations
H.264 video encoder:
1. `--pass 1 …` first analysis pass over the input YUV.
2. `--pass 2 …` second encode pass (uses stats from pass 1).
3. a separate `--seek … --dumpyuv …` encode of `BuckBunny.yuv` at 1280x720.
Memory: moderate (reference frame buffers); compute-heavy.

### 557.xz_r — 6 invocations
LZMA (xz) compress/decompress driven by `xz/args.c` over two corpora
(`cld.tar.xz`, `cpu2006docs.tar.xz`) at varying compression levels and block sizes,
each as `xz_r <file>.xz <size> <sha512> <min> <max> <levels>`.
Memory: large dictionaries/buffers → sizable footprint; another good memory-intensive
candidate if multi-invocation support is added.

## Implementation sketch (for the build phase, not yet done)

1. **`setup.sh` (SPEC block)** — runs by default when `$SPEC_SRC`
   (default `/proj/instrument-PG0/spec`) exists; auto-skips otherwise; force-skip
   with `BUILD_SPEC=0`.
   - `apt install gcc g++ gfortran rsync` (Fortran toolchain needed for the FP set).
   - `rsync $SPEC_SRC` → `$SPEC_DEST` (default `$HOME/spec`).
   - Write `config/clean-gcc.cfg` from `Example-gcc-linux-x86.cfg`: `gcc_dir=/usr`,
     `label=clean`, plus a `520.omnetpp_r: CXXPORTABILITY = -std=gnu++14` stanza
     (drops the C++17 3-arg `std::hypot` overload that breaks omnetpp at runtime).
   - `source shrc && runcpu --config=clean-gcc --action=build <subset ids>`.
   - `runcpu --config=clean-gcc --action=setup --size=ref <subset ids>` to stage
     `run_base_refrate_clean-m64.0000` dirs with inputs.

2. **`scripts/workloads/spec.sh`**
   - `config_spec`: set `SPEC_PATH=$SPEC_DEST`, `WORK_SIZE=ref`, `LABEL=clean-m64`.
   - `translate_workload`: `-w` short name → `NNN.name_r`.
   - `run_spec`: glob the refrate run dir
     (`$SPEC_PATH/benchspec/CPU/<id>/run/run_base_refrate_${LABEL}.*` — take first),
     resolve the exe under `exe/<exe>_base.${LABEL}`, look up the per-benchmark arg
     string (table keyed by `-w` name), then build the wrapper to **`cd` into the run
     dir** before exec. Use `generate_workload_filenames` + `run_workload_standard`
     with `--cpunodebind=0 --membind=0`.
   - For `roms`, the arg string includes a stdin redirect (`< ocean_benchmark2.in.x`),
     which works because the wrapper writes `exec "$bin" $args` literally.

3. **Wrapper working-directory gap**
   `create_workload_wrapper` currently `exec`s from the repo root with no `cwd` support.
   Add an optional `work_dir` parameter that emits `cd "$work_dir"` before the `exec`
   line (backward-compatible 6th arg), OR pass `cd "<rundir>"` via the existing
   `extra_env_vars` parameter (it is echoed verbatim before exec). Prefer the explicit
   parameter.

4. **Docs**: add the `spec` row details to `CLAUDE.md`'s workload index
   (supported `-w` names = the subset above).
