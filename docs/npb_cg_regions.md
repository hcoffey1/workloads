# NPB-CG application regions

`NPB-CPP/NPB-OMP/bin/cg.<CLASS>` supports three persistent application-defined
REGENT zones. The other NPB kernels are unchanged.

| App id | Runtime id | Zone | Buffers | Contents |
|---|---|---|---|---|
| 0 | 1 | `matrix` | `a`, `colidx` | Active nonzero prefixes (`nnz = rowstr[nrows]`) traversed together in every sparse matrix-vector product |
| 1 | 2 | `gather_vectors` | `p`, `z` | Vectors read indirectly through `colidx` (`A·p` in the CG iterations, `A·z` in the residual) |
| 2 | 3 | `streaming_state` | `x`, `q`, `r`, `rowstr` | Direct vector sweeps, reductions, and row-bound scans |

Grouping `rowstr` with the streamed vectors is an initial simplification; it
is a separate buffer in the manifest so it can be split later. Matrix
generation scratch (`iv`, `arow`, `acol`, `aelt`) stays unmanaged with its
original lifetime and is listed under `unmanaged`.

## Build and direct invocation

```bash
make -C NPB-CPP/NPB-OMP cg CLASS=S      # or the harness's Class D
python3 NPB-CPP/NPB-OMP/CG/tests/test_cg_regions.py
```

`CG/Makefile` adds `-I../../../common` and `-ldl`. Zoning requires the default
dynamic-allocation build; the static-array build
(`DO_NOT_ALLOCATE_ARRAYS_WITH_DYNAMIC_MEMORY_AND_AS_SINGLE_DIMENSION`) still
runs unzoned and rejects both region options at startup. The NPB binary took
no arguments before; it now accepts only the zoning options and rejects
anything else.

```bash
REGENT_REGION_MODE=application REGENT_FAST_MEMORY=2M \
LD_PRELOAD=/absolute/path/to/libarms_kernel.so OMP_NUM_THREADS=8 \
NPB-CPP/NPB-OMP/bin/cg.D --app-regions \
  --app-region matrix:simple_frequency:0 \
  --app-region gather_vectors:simple_frequency:0 \
  --app-region streaming_state:simple_frequency:0
```

| Option | Default / validation |
|---|---|
| `--app-regions` | Off; requires application runtime mode and all three declarations |
| `--app-region NAME:POLICY:BYTES` | Exactly one per zone; order is immaterial |
| `--region-layout-only` | Off; same mapped layout without registration; mutually exclusive with application regions |
| `--warmups N` | Rejected: CG's untimed first iteration is its fixed warmup |

Policy names, size units, 2 MB budget granularity, the `REGENT_FAST_MEMORY`
fit check, incompatible automatic-mode settings, and failure-before-measurement
follow [MERCI zoning](merci_regions.md). Every buffer of a zone is registered
with the zone's id and whole budget.

## Harness configuration

```bash
HEMEMPOL=/absolute/path/to/libarms_kernel.so REGENT_FAST_MEMORY=2M \
NPB_CG_REGION_MODE=application \
NPB_CG_MATRIX_POLICY=simple_frequency          NPB_CG_MATRIX_FAST=0 \
NPB_CG_GATHER_VECTORS_POLICY=simple_frequency  NPB_CG_GATHER_VECTORS_FAST=0 \
NPB_CG_STREAMING_STATE_POLICY=simple_frequency NPB_CG_STREAMING_STATE_FAST=0 \
NUMA_PLACEMENT=slow-bind ./run.sh -b npb-cpp -w cg -o results/cg_regions
```

| Variable | Default / meaning |
|---|---|
| `NPB_CG_REGION_MODE` | `off`, `layout`, or `application`; default `off`; only valid for `cg` |
| `NPB_CG_<ZONE>_POLICY`, `NPB_CG_<ZONE>_FAST` | Required for every zone in application mode; rejected otherwise |

`<ZONE>` is `MATRIX`, `GATHER_VECTORS`, or `STREAMING_STATE`. The harness
builds Class D (`config_npb-cpp`) with a clean rebuild every run. Both region
modes write `*_regions.json` beside the outputs via
`scripts/workloads/regions_metadata.py`, including `npbparams.hpp` so the
class is fingerprinted.

## Allocation and measurement

The dynamic build no longer allocates its arrays from static initializers;
`allocate_arrays()` runs after the options are parsed and either mallocs the
original sizes (legacy) or assigns the existing typed pointers to dedicated
mappings. `a` and `colidx` keep their `NZ` capacity for `makea` but are mapped
without prefaulting, so untouched capacity costs no physical memory, as with
the original lazy `malloc`. After `makea`, only the active prefix of each
(rounded up to whole 2 MB pages inside the mapping) is write-touched and
registered; the manifest reports `matrix_capacity_entries`,
`matrix_active_entries`, and `matrix_active_bytes`. The vectors and `rowstr`
are fully prefaulted at allocation.

Registration happens once on the main thread before the OpenMP parallel
region opens, so no worker can start the solver before every declaration has
succeeded. The column-index normalization, vector initialization, untimed
first iteration, reset, and `T_BENCH` boundary are unchanged. `CG_EVENT`
markers record `prepare_begin`, `registration_begin`, `regions_ready`, the
untimed iteration as `warmup_begin`/`warmup_end` (trial `-1`, observed from
the master thread), and `kernel_begin`/`kernel_end` around `T_BENCH`.

The primary metric remains the verified NPB `Time in seconds` with
`Mop/s total`. At Class D one vector is roughly 11.4 MiB; cache capacity may
limit the benefit of fast-tier placement for the gathered vectors.

## Validation

`NPB-CPP/NPB-OMP/CG/tests/test_cg_regions.py` builds Class S, compiles the
shared fake registration library, and checks: verification in every mode,
identical zeta between legacy and layout runs, registration order and exact
range sizes (active prefix only, capacity kept mapped), shared-zone budgets,
lifetime to process exit, marker ordering, every failure mode stopping before
the benchmark, zero budgets, and harness wrapper quoting and mode selection.
Target-machine THP backing, placement, and migration outcomes are not
covered; check them before interpreting timing.
