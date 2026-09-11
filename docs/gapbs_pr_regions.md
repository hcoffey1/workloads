# GAPBS PageRank application regions

`gapbs/pr` supports four persistent application-defined REGENT zones. The other
GAPBS kernels retain their existing allocation behavior; `pr_spmv` is unchanged.

| App id | Runtime id | Zone | Buffers | Contents |
|---|---|---|---|---|
| 0 | 1 | `incoming_edges` | `in_neighbors` | Final incoming neighbor lists traversed by the pull loop |
| 1 | 2 | `contributions` | `outgoing_contrib` | Per-vertex `score / out_degree`, gathered through neighbor ids |
| 2 | 3 | `scores` | `scores` | Per-vertex scores, updated directly with the convergence check |
| 3 | 4 | `vertex_index` | `in_index`, `out_index` | CSR pointer indices, `(V+1)` pointers each |

An undirected graph (`-g`, `-u`, or `-s`) aliases both CSR structures: the
zone `incoming_edges` then holds the single neighbor array and `vertex_index`
holds one index. On a directed graph the outgoing neighbor payload stays
unmanaged: PageRank reads only its index (for degrees), and `-v` verification
traverses it outside the timed trial. The manifest lists it under `unmanaged`.
Graph building, the edge list, and the verifier's scratch remain unmanaged.

## Build and direct invocation

```bash
make -C gapbs pr
python3 gapbs/test/test_pr_regions.py
```

The Makefile adds `-I../common` (override with `REGIONS_DIR`) and `-ldl` for
every kernel; only `pr` includes the helper. Zoning options are long options
extracted before GAPBS's getopt parser sees the command line, so all existing
short options keep their meaning:

```bash
REGENT_REGION_MODE=application REGENT_FAST_MEMORY=2M \
LD_PRELOAD=/absolute/path/to/libarms_kernel.so \
gapbs/pr -g 20 -n 20 -v --warmups 1 --app-regions \
  --app-region incoming_edges:simple_frequency:0 \
  --app-region contributions:simple_frequency:0 \
  --app-region scores:simple_frequency:0 \
  --app-region vertex_index:simple_frequency:0
```

| Option | Default / validation |
|---|---|
| `--app-regions` | Off; requires application runtime mode and all four declarations |
| `--app-region NAME:POLICY:BYTES` | Exactly one per zone; order is immaterial |
| `--region-layout-only` | Off; same relocated layout and persistent workspace without registration; mutually exclusive with application regions |
| `--warmups N` | 0; extra timed-but-excluded trials before the `-n` measured trials |
| `-n`, `-i`, `-t`, `-v`, `-a`, `-l` | GAPBS options, unchanged; zoned runs need `-n` > 0 |

Policy names, size units, 2 MB budget granularity, the `REGENT_FAST_MEMORY`
fit check, incompatible automatic-mode settings, and failure-before-measurement
follow [MERCI zoning](merci_regions.md). `vertex_index` registers two ranges on
a directed graph with the same id and the whole zone budget; registration
resets the budget, it does not accumulate.

## Harness configuration

```bash
HEMEMPOL=/absolute/path/to/libarms_kernel.so REGENT_FAST_MEMORY=2M \
GAPBS_PR_REGION_MODE=application \
GAPBS_PR_INCOMING_EDGES_POLICY=simple_frequency GAPBS_PR_INCOMING_EDGES_FAST=0 \
GAPBS_PR_CONTRIBUTIONS_POLICY=simple_frequency  GAPBS_PR_CONTRIBUTIONS_FAST=0 \
GAPBS_PR_SCORES_POLICY=simple_frequency         GAPBS_PR_SCORES_FAST=0 \
GAPBS_PR_VERTEX_INDEX_POLICY=simple_frequency   GAPBS_PR_VERTEX_INDEX_FAST=0 \
NUMA_PLACEMENT=slow-bind ./run.sh -b gapbs -w pr -o results/pr_regions
```

| Variable | Default / meaning |
|---|---|
| `GAPBS_PR_REGION_MODE` | `off`, `layout`, or `application`; default `off`; only valid for `pr` and `pr_twitter` |
| `GAPBS_PR_<ZONE>_POLICY`, `GAPBS_PR_<ZONE>_FAST` | Required for every zone in application mode; rejected otherwise |
| `GAPBS_PR_WARMUPS` | Optional excluded warmup trials |

`<ZONE>` is the upper-cased zone name (`INCOMING_EDGES`, `CONTRIBUTIONS`,
`SCORES`, `VERTEX_INDEX`). The shared helper `regent_zones_prepare_args` in
`scripts/workload_utils.sh` builds the arguments and the wrapper's runtime-mode
lines exactly as for MERCI. Thread count and repetition count keep their
`config_gapbs` values (8 and 20). Both region modes write
`*_regions.json` beside the outputs via `scripts/workloads/regions_metadata.py`
(binary, wrapper, source, helper, harness, and policy-library fingerprints,
plus the workloads and `gapbs` repository revisions).

## Allocation and measurement

After `Builder::MakeGraph` returns the final graph (synthetic, edge-list, or
serialized `.sg`, with or without `-m`), `CSRGraph::AdoptStorage` moves the
incoming neighbor array and the pointer indices into dedicated mappings from
`common/regent_regions/regions.h`: incoming pointers are rebuilt against the
new base, outgoing pointers are copied as they are, and the replaced heap
arrays are released. The graph never frees adopted storage; the zones object
outlives the graph and registered mappings stay valid until process exit.

`scores` and `outgoing_contrib` become a persistent workspace allocated once
before the trial loop; `PageRankPullGSCore` initializes them at the start of
each trial, inside the trial time as before. Registration happens once on the
main thread after relocation and prefaulting, before any warmup or trial.

`Average Time:` remains the mean of the `-n` measured trials. Each trial also
emits `PR_TRIAL {"trial","iterations","seconds","iterative_seconds"}` where
`iterative_seconds` excludes the initialization loops; warmups print
`Warmup Time:` and negative trial ids. `PR_EVENT` markers cover preparation,
registration, `regions_ready`, and each kernel's begin/end using captured
timestamps. Parallel floating-point trials need not match bitwise; the
existing `-v` verifier reports `Total Error` per trial.

`REGENT_ZONE_MANIFEST` uses schema version 2: each zone lists its buffers with
bases and logical/mapped/registered bytes, zone-level totals, policy and
budget, plus graph identity (input, directedness, node and edge counts),
trial settings, and unmanaged arrays.

## Validation

`gapbs/test/test_pr_regions.py` builds `pr`, compiles the shared fake
registration library (`common/regent_regions/tests/fake_regent.cpp`), and
checks: directed and undirected graphs, in-place and squished building,
duplicate/self edges and isolated vertices, identical top scores against the
legacy path, registration order and range sizes, shared-zone budgets, lifetime
to process exit, warmup accounting, every failure mode stopping before the
first trial, zero budgets, harness wrapper quoting and mode selection, and
provenance capture. Target-machine THP backing, placement, and migration
outcomes are not covered; check them before interpreting timing.
