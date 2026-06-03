# Benchmark Suite
https://duckdb.org/docs/current/dev/benchmark

To build the benchmark suite:
```
BUILD_BENCHMARK=1 BUILD_EXTENSIONS='tpch;tpcds' make
```

List benchmarks:
```
build/release/benchmark/benchmark_runner --list
```

Running a single benchmark and (optionally) write the results to `timings.out`:
```
build/release/benchmark/benchmark_runner benchmark/micro/nulls/no_nulls_addition.benchmark --out=timings.out
```

To run all benchmarks
```
build/release/benchmark/benchmark_runner
```

To learn more about a benchmark:
```
build/release/benchmark/benchmark_runner benchmark/micro/nulls/no_nulls_addition.benchmark --info --query --profile
```
Flags should be run separately. `--profile` runs the benchmark and gives detailed breakdown.


I want to run ./build/release/benchmark/benchmark_runner "benchmark/large/tpcds-sf100/.*"   with the run.sh harness.
