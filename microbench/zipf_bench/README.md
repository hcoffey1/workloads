# zipf_bench

Page-granular Zipfian memory access microbenchmark. A buffer is split into
pages; each access draws a page rank from a Zipf distribution (P(k) ∝ 1/k^θ),
maps it to a page, and touches one random cache line in it. Sampling uses
rejection-inversion, which is exact and needs no lookup table, so the only
memory traffic is the buffer itself plus a 4 B/page rank→page permutation
(whose hot entries stay cached).

## Build / Run

```bash
make
./zipf_bench --size-gb 32 --hot-frac 0.2 --hot-access 0.8 --duration-s 60 --threads 8
# via the harness (defaults below)
./run.sh -b zipf_bench -w zipf_bench -o results/zipf
```

| Flag | Harness env var | Default | Meaning |
|---|---|---|---|
| `--bytes N` / `--size-gb G` | `ZIPF_BENCH_BYTES` | 32 GiB | Buffer size |
| `--page-size N` | `ZIPF_BENCH_PAGE_SIZE` | 4096 | Access granularity ("page") |
| `--duration-s S` | `ZIPF_BENCH_DURATION` | 60 | Timed run length |
| `--hot-frac F` | `ZIPF_BENCH_HOT_FRAC` | 0.2 | Hottest fraction of pages… |
| `--hot-access A` | `ZIPF_BENCH_HOT_ACCESS` | 0.8 | …receives this fraction of accesses; θ is solved for |
| `--theta S` | `ZIPF_BENCH_THETA` | unset | Set the Zipf exponent directly (overrides the above) |
| `--threads N` | `ZIPF_BENCH_THREADS` | 1 (harness: 8) | Worker threads |
| `--seed N` | `ZIPF_BENCH_SEED` | 1 | RNG seed (also fixes the page permutation) |
| `--no-shuffle` | `ZIPF_BENCH_SHUFFLE=0` | scattered | Place hot ranks contiguously at the buffer start |
| `--no-prefault` | `ZIPF_BENCH_PREFAULT=0` | prefault | Skip touching the buffer before the timed run |
| `--read-only` | `ZIPF_BENCH_READONLY=1` | write | Loads instead of increments |

| `--no-pin` | `ZIPF_BENCH_PIN=0` | pinned | Don't pin workers (one per physical core by default) |
| `--cpus LIST` | — | auto | Explicit worker CPUs, e.g. `0-7` |
| `--perf-out PREFIX` | `ZIPF_BENCH_PERF=1` | harness: on | Enable PEBS L3-miss sampling, write `PREFIX_*` |
| `--perf-period N` | `ZIPF_BENCH_PERF_PERIOD` | 1007 | PEBS sample period (period mode, not frequency) |
| `--perf-ring-pages N` | `ZIPF_BENCH_PERF_RING_PAGES` | 512 | Per-core ring buffer data pages (power of 2) |
| `--perf-miss-event X` | — | 0x20d1 | Raw config (`MEM_LOAD_RETIRED.L3_MISS`) |
| `--perf-keep-all` | — | off | Also log samples outside the buffer |

Output reports the solved θ, the analytic hot-set share, and the observed
share of accesses that hit the hot set (it should match the target).
For 32 GiB / 4 KiB pages, 80/20 gives θ ≈ 0.884.

## PEBS L3-miss sampling

With `--perf-out PREFIX` every worker is pinned to its own physical core
(chosen from the process's allowed CPUs, so `numactl --cpunodebind` is
respected) and opens `MEM_LOAD_RETIRED.L3_MISS` in PEBS period mode on that
core. A monitor thread, pinned to a separate core, drains the per-core rings:

| File | Contents |
|---|---|
| `PREFIX_samples.bin` | 24-byte records `time_ns u64, addr u64, thread u16, event u8, pad[5]` (perf clock) |
| `PREFIX_lost.csv` | `PERF_RECORD_LOST`/`LOST_SAMPLES`/`(UN)THROTTLE` records, per core |
| `PREFIX_meta.json` | buffer range, θ, CPUs, run window (perf clock), counter totals |
| `PREFIX_perm.bin` | u32 rank→page map (scattered layout only) |

By default only samples inside the buffer are written; the rest (mostly misses
on the rank→page map) are counted in the meta file. The summary also reports
`unaccounted` = 1 − samples×period / counter value, so silent PEBS record loss
shows up (0.0% in the default config).

Plot a heatmap (time × VA, or × Zipf rank with `--by-rank`) and the
cumulative % pages vs % samples curve:

```bash
python scripts/vis/plot_zipf_bench.py PREFIX [--by-rank]   # needs numpy+matplotlib (e.g. dataVis env)
```

In the default 32 GiB / 60 s run there are ~0.15 samples per page, so the
curve ranked by observed sample counts is meaningless (it hits 100% at <10% of
pages). The plot's solid curve ranks pages by their true Zipf rank instead,
which is unbiased. The L3-miss curve sits below the analytic access curve
(75.5% vs 80% in the hot set) because the very hottest pages hit in cache.
