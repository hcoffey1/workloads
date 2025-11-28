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
