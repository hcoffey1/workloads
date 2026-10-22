# Intro
Fork of: https://github.com/SujayYadalam94/workloads

Collection of benchmarks with a focus on workloads with high memory usage (bandwidth/RSS).

Includes an experiment harness for automatically building/running benchmarks. A `setup.sh` script
is provided to patch some workloads and build executables.

# Experiment Harness
`run.sh` is the starting point for invoking the harness. You can find how current workloads are invoked,
or add support for more, following the pattern in `./scripts/workloads/*.sh`.

```
Usage: ./run.sh -b benchmark_suite -w workload -o output_dir [OPTIONS]

EXAMPLES:
  ./run.sh -b graph500 -w graph500 -o results/baseline
  ./run.sh -b gapbs -w bfs -o results/test -i damon -s 1000 -a 50 # Monitor with DAMON
  ./run.sh -b gapbs -w bc -o results/test -i pebs -s 1000         # Monitor with Intel PEBS
  ./run.sh -b xsbench -w xsbench -o results/multi -r 5            # Run 5 iterations
```

# Workload Status
Smoke-tested 2026-10-22 with `scripts/smoke.sh`: each suite is run once through `run.sh`; the lazy
build gets up to 45 min, then the run is capped at 5 min. **RUNNING** = built and still running at
the cap (starts fine, output not checked). *Last measured* is the peak-RSS date in
`config/workload_descriptors/` ("undated" = descriptor without a date, "—" = no descriptor).

Pinning: **fork** = hcoffey1 fork submodule, **upstream** = upstream submodule, **copy** = upstream
source copied in-tree, **own** = our code in-tree.

| Suite | Pinning | `setup.sh` job | Last measured | Smoke | Notes |
|---|---|---|---|---|---|
| gapbs | fork | yes | 2026-05-21 | PASS | |
| flexkvs | copy | yes | — | PASS | |
| silo | upstream + patch (Bitbucket) | yes | undated | PASS | |
| cloverleaf | upstream | no | undated | PASS | |
| llama_cpp | upstream | no | — | PASS | |
| dcperf | upstream | no | — | PASS | 12 min first build |
| mscrush | upstream | no | — | PASS | |
| faiss | fork | no | 2026-05-18 | PASS | |
| renaissance | upstream | no | 2026-05-25 | PASS | |
| micro_interference | own | no | 2026-05-21 | PASS | needs `cpufreq_monitor` from outside the repo |
| micro_phase | own | no | — | PASS | |
| minimap2 | upstream | submodule init only | — | PASS | default `test` dataset is tiny (5 MB RSS) |
| memcached | upstream (+YCSB) | no | — | PASS | YCSB load is ~1k ops, not memory-intensive |
| xsbench | upstream | yes | undated | RUNNING | |
| graph500 | fork | yes | 2026-06-24 | RUNNING | |
| merci | copy | yes | undated | RUNNING | needs `cpufreq_monitor` from outside the repo |
| liblinear | copy | yes | undated | RUNNING | |
| npb-cpp | fork | TBB only | 2026-05-21 | RUNNING | |
| spec | SPEC tarball | yes | 2026-06-25 | RUNNING | |
| spec2026 | SPEC ISO | yes | 2026-07-13 | RUNNING | |
| ogb | own | no | 2026-06-15 | RUNNING | conda env missing numpy |
| duckdb | fork | no | 2026-05-18 | BUILD_TIMEOUT | still compiling at 45 min; untested |
| gups | copy | no | — | FAIL | `run_gups()` is all comments, script won't load |
| masim | fork | no | — | FAIL | fork doesn't compile: `RAND_ARR_SZ` undeclared |
| cachelib | fork | no | — | FAIL | dependency `googleflags` fails to build |
| ann-solo | fork (+faiss) | no | — | FAIL | pinned `lancedb<0.4` no longer on pip |
| seq_slope_bench | missing | no | — | FAIL | source directory doesn't exist |

Unused submodules (no workload script references them): `redis`, `vmitosis-workloads`, `giab_data_indexes`.
