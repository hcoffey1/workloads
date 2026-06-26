# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a benchmarking suite for memory-intensive workloads (high bandwidth/RSS), with a unified experiment harness for building and running diverse benchmarks with optional memory access instrumentation. It is a fork of [SujayYadalam94/workloads](https://github.com/SujayYadalam94/workloads).

## Setup

Build all workloads from scratch:
```bash
./setup.sh
```

This initializes submodules, installs system deps (`libnuma-dev libpmem-dev libaio-dev libssl-dev mpich`), applies patches from `patches/`, and builds each workload. To build an individual workload, follow the corresponding block in `setup.sh`.

## Running Experiments

```bash
# Minimal invocation
./run.sh -b <suite> -w <workload> -o <output_dir>

# With DAMON memory monitoring
./run.sh -b gapbs -w bfs -o results/test -i damon -s 1000 -a 50

# With Intel PEBS page tracking
./run.sh -b gapbs -w bc -o results/test -i pebs

# Multiple iterations
./run.sh -b xsbench -w xsbench -o results/multi -r 5

# With YAML config and cgroup isolation
./run.sh -b gapbs -w bfs -o results/test -f config.yaml --use-cgroup
```

Key flags: `-b` suite, `-w` workload, `-o` output dir, `-f` config YAML, `-i` instrumentation (`pebs`|`damon`), `-r` iterations, `--record-vma`, `--use-cgroup`.

## Architecture

### Harness Flow

`run.sh` is the main entry point. It:
1. Parses arguments and sources `scripts/workload_utils.sh`
2. Sources the matching workload script from `scripts/workloads/<suite>.sh`
3. Calls `config_<workload>()`, then `run_<workload>()` for each iteration

Each workload script in `scripts/workloads/` defines three functions: `config_<workload>()`, `build_<workload>()`, and `run_<workload>()`. Adding a new workload means adding a new script following this pattern.

### Workload Execution

`scripts/workload_utils.sh` provides two key helpers used by all workload scripts:

- **`generate_workload_filenames <workload>`** — sets exported vars `TIMEFILE`, `STDOUT`, `STDERR`, `BWMON`, `MPSTAT`, `PERFMON`, `CPUFREQ`, `PIDFILE`, `WRAPPER` with a consistent naming scheme: `{OUTPUT_DIR}/{suite}_{workload}_{hemem_policy}_{DRAMSIZE}_iter{N}_{metric}.txt`

- **`create_workload_wrapper <wrapper_path> <pidfile> <binary> [args] [extra_env]`** — generates a shell wrapper script that records the process PID, sets `LD_PRELOAD` (for `HEMEMPOL` memory policy interposition and `SYS_ALLOC`), then execs the workload binary under `time`.

### Memory Instrumentation

Two instrumentation backends controlled by `-i`:
- **PEBS** (`scripts/PEBS_page_tracking/`): Intel PEBS-based per-page memory access tracking. Requires the kernel patch in `patches/pebs.patch`.
- **DAMON** (`scripts/damo/`): Linux DAMON subsystem interface for memory access monitoring. Tunable via `-s` (sampling rate µs), `-a` (aggregation rate ms), `-n`/`-m` (region counts).

### Memory Policy (HeMem)

The harness supports interposing a memory allocation policy via `LD_PRELOAD` through the `HEMEMPOL` environment variable (points to a `libhemem*.so`). The policy name is extracted from the `.so` filename and embedded in output filenames. Set `DRAMSIZE` to control the DRAM size budget passed to the policy.

### Patches

`patches/` contains the `silo.patch` git patch that must be applied before building the `silo` submodule. `setup.sh` applies it automatically; apply individually with `git apply ../../patches/silo.patch` from within the `silo/silo` directory.

## Workload Index

| Suite flag (`-b`) | Workload flag (`-w`) | Notes |
|---|---|---|
| `graph500` | `graph500` | |
| `gapbs` | `bfs`, `sssp`, `pr`, `cc`, `bc`, `tc` | Requires graph files in `gapbs/benchmark/graphs/` |
| `xsbench` | `xsbench` | |
| `flexkvs` | `flexkvs` | |
| `silo` | `silo` | |
| `merci` | `merci` | Requires dataset download via `setup.sh` |
| `liblinear` | `liblinear` | Requires `kdd12` dataset download via `setup.sh` |
| `gups` | `gups` | |
| `masim` | `masim` | Memory access simulator |
| `npb-cpp` | varies | NAS Parallel Benchmarks |
| `cloverleaf` | `cloverleaf` | |
| `minimap2` | `minimap2` | Requires genome data |
| `llama_cpp` | `llama_cpp` | Requires model weights |
| `dcperf` | varies | Meta DCPerf suite |
| `memcached` | `memcached` | |
| `cachelib` | `cachelib` | |
| `ann-solo` | `ann-solo` | |
| `mscrush` | `mscrush` | |
| `spec` | `mcf`, `bwaves`, `lbm`, `omnetpp`, `xalancbmk`, `cactuBSSN`, `fotonik3d`, `roms`, `deepsjeng` (also `leela`, `imagick`) | SPEC CPU2017 refrate, clean -O3 gcc build. Built by `./setup.sh` when the SPEC source is present (`SPEC_SRC`, default `/proj/instrument-PG0/spec`); auto-skipped otherwise, force-skip with `BUILD_SPEC=0`. Override run path with `SPEC_PATH`. `bwaves` is multi-invocation (4 independently-tracked sub-runs `spec_bwaves_1`..`spec_bwaves_4`). `parest` excluded (deal.II doesn't build with gcc 11). See `docs/spec2017_integration.md`. |
| `ogb` | `products` (ogbn-products), `papers100M` (ogbn-papers100M, opt-in heavy) | GraphSAGE mini-batch training (PyG `NeighborLoader`). Exhibits three concurrent memory patterns: sparse topology walks, random feature gathers, dense GEMM. CPU-pinned. Lazy `build_ogb` provisions a dedicated `ogb` conda env (CPU-only torch+PyG) and downloads the dataset. Tunables: `OGB_EPOCHS`, `OGB_BATCH_SIZE`, `OGB_NUM_WORKERS` (default 0 = single OMP-threaded process). See `docs/ogb_integration.md`. |
