# MERCI application regions

`MERCI/4_performance_evaluation/bin/eval_baseline` supports two persistent
application-defined REGENT regions. Other MERCI evaluation executables retain
their existing allocation behavior.

| App id | Runtime id | Name | Contents |
|---|---|---|---|
| 0 | 1 | `embedding` | Embedding rows selected indirectly by feature ids |
| 1 | 2 | `output` | Per-query output rows accumulated by each worker |

Each row contains `EMBEDDING_DIM` floats (currently 64). Query vectors, their
worker-partition copies, cache-flush memory, and thread/runtime allocations
remain unmanaged. Region budgets do not bound whole-process residency.

## Build and direct invocation

```bash
make -C MERCI/4_performance_evaluation -j
make -C MERCI/4_performance_evaluation test
```

Input remains `$HOME/MERCI/data/4_filtered/NAME/NAME_test_filtered.txt`.
The harness points `HOME` at the workloads root; set the appropriate data root
for direct invocation too. This example exercises zero-budget placement, not
a recommended performance configuration:

```bash
REGENT_REGION_MODE=application REGENT_FAST_MEMORY=2M \
LD_PRELOAD=/absolute/path/to/libarms_kernel.so \
MERCI/4_performance_evaluation/bin/eval_baseline \
  -d amazon_All -c 8 -r 20 --app-regions \
  --app-region embedding:simple_frequency:0 \
  --app-region output:simple_frequency:0 --shuffle-seed 1
```

Direct invocation inherits the caller's NUMA placement. Setting
`NUMA_PLACEMENT` on the binary only records a request; use the harness to
actually apply that placement policy.

| Option | Default / validation |
|---|---|
| `--app-regions` | Off; requires application runtime mode and both declarations |
| `--app-region NAME:POLICY:BYTES` | Exactly one each for `embedding` and `output`; order is immaterial |
| `--region-layout-only` | Off; same mapped layout/preparation without registration, mutually exclusive with application regions |
| `--shuffle-seed N` | Unsigned 32-bit seed; defaults to 1 in either region mode, random in legacy mode unless specified |
| `--warmups N` | 0; additional excluded kernel trials, nonnegative integer |
| `--verify` | Off; serial reference check after every trial, for diagnostics rather than policy timing |
| `-d` / `--dataset` | Required dataset name |
| `-c`, `-r` | Positive thread and measured-repetition counts; direct defaults are hardware concurrency and 5 |

Policies currently qualified for application mode are `simple_frequency` and
`evolve`. Sizes accept unsigned bytes or one uppercase `K/M/G/T` suffix with
binary multipliers (`64M`, not `64MB` or `64MiB`). Budgets must be multiples of
2 MB; zero is valid. The unique-zone total must fit explicit
`REGENT_FAST_MEMORY`. Unknown/duplicate/missing declarations, bad values, a
missing API, or registration failure stop execution before the measured kernel.
Direct application runs must unset `REGENT_NO_CLUSTERING`,
`REGENT_CLUSTER_CONFIG`, and `REGENT_REBALANCER`.

Without either region option, storage stays vector-backed and REGENT is
optional. For the layout baseline use `--region-layout-only`, no preload, and
no application runtime mode. With `evolve`, set `REGENT_EVOLVE_CANDIDATE` to the
candidate shared object. All `evolve` regions currently share one candidate;
use a single evolved target with a `simple_frequency` background to compare
policies for one zone.

## Harness configuration

```bash
HEMEMPOL=/absolute/path/to/libarms_kernel.so REGENT_FAST_MEMORY=2M \
MERCI_REGION_MODE=application MERCI_SHUFFLE_SEED=1 \
MERCI_EMBEDDING_POLICY=simple_frequency MERCI_EMBEDDING_FAST=0 \
MERCI_OUTPUT_POLICY=simple_frequency MERCI_OUTPUT_FAST=0 \
NUMA_PLACEMENT=slow-bind ./run.sh -b merci -w merci -o results/merci_regions
```

| Variable | Default / meaning |
|---|---|
| `MERCI_REGION_MODE` | `off`, `layout`, or `application`; default `off` |
| `MERCI_EMBEDDING_POLICY`, `MERCI_OUTPUT_POLICY` | Required in application mode |
| `MERCI_EMBEDDING_FAST`, `MERCI_OUTPUT_FAST` | Required fixed budgets in application mode |
| `MERCI_DATASET` | `amazon_All` |
| `MERCI_THREADS`, `MERCI_REPEATS` | 8 and 20; positive integers |
| `MERCI_SHUFFLE_SEED` | Optional explicit seed; otherwise binary defaults above |
| `MERCI_WARMUPS` | 0; excluded warmup trials |
| `MERCI_VERIFY` | 0 or 1; default 0 |

The application wrapper selects application runtime mode and unsets the three
incompatible automatic-mode settings. The layout wrapper removes `LD_PRELOAD`
and application runtime mode. Policy/budget variables are rejected outside
application mode. Both region modes set OpenMP thread count to `MERCI_THREADS`
for cache flushing as well as the reduction's explicit worker count. Other
harness NUMA/cgroup settings retain their meanings.

The legacy `run_strace_merci` helper does not configure zoning. Use the main
harness or pass documented options directly for region experiments.

## Allocation and measurement

The C++11 helper in `common/regent_regions/regions.h` uses dedicated anonymous
mappings with a 2 MB aligned base and padded length. It requests THP and
write-prefaults the entire mapping, including padding, before registration.
`madvise` is a request, not evidence of THP backing. The reduction's indexed
accesses use a stored pointer without a layout-mode branch.

Both buffers are prepared and registered once before workers launch. Output
resets do not resize its backing storage. Registered mappings stay valid until
process exit because the API has no unregister operation; application
objects do not unmap them while runtime workers may still be running.
Unregistered mapped buffers and legacy vectors retain normal cleanup.

`Average Time:` remains the arithmetic mean of the `-r` measured reduction
intervals, in milliseconds. Allocation, registration, output reset, cache
flush, verification, and warmup trials are excluded. Each measured and warmup
trial time is retained. Policies can observe reset and verification traffic;
keep protocols identical between comparison arms and disable verification for
timing runs. Warmups execute actual reductions and reset output before the
next trial; no fixed count guarantees policy convergence.

Region runs emit one `REGENT_ZONE_MANIFEST` JSON object with bases,
logical/mapped/registered bytes, ids, policies, budgets, seed, query-order
fingerprint, and unmanaged query payload capacities. `query_order_fnv1a64`
hashes each shuffled query's length followed by its feature ids as
little-endian 64-bit words. It is a reproducibility diagnostic, not a
cryptographic identity; reproduction also requires the same binary and
standard library shuffle implementation.

`MERCI_EVENT` JSON records mark preparation, registration, reset, cache-flush
completion, and timed kernels using monotonic nanoseconds. Negative trial ids
identify warmups; measured trials start at 0. Kernel markers are emitted after
joining workers using captured timestamps, keeping logging outside the timed
interval. `MERCI_VERIFY` records contain row counts and output checksums.

Before execution, the harness writes `*_regions.json` beside normal outputs.
It fingerprints input, binary, generated wrapper, relevant source/build
scripts, and configured policy libraries with SHA-256, and records repository
revisions, tracked diffs, and requested environment settings. Input hashing
can take time and occurs outside the workload invocation. The wrapper and
stdout manifest define effective settings; recorded environment values may
include automatic-mode settings subsequently unset by the wrapper.

## Validation and remaining hardware work

`make test` builds all three evaluation binaries and uses a generated dataset
and fake registration library. It checks alignment, padding residency, exact
calls, lifetime through object destruction, failures before measurement,
reproducible seeds, warmup accounting, serial-reference results, strict
configuration, shell quoting, provenance, and the C++11 buffer contract. It
requires no dataset download, root access, NUMA movement, or PEBS.

Before performance comparisons, verify THP backing, ownership, actual
placement, fixed budgets, and migration outcomes on the target machine.
Compare legacy and mapped-layout baselines, then all-`simple_frequency` and
single-zone `evolve` runs with identical input order, warmups, CPU/NUMA
placement, and fixed budget vectors. Select nonzero budgets from measured
footprints and baseline sensitivity curves. Hardware-free checks do not
establish performance improvement.
