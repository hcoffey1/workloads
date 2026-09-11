# 4. Performance Evaluation

```bash
$ make all embedding_dim=${embeding_dimension}
```
## Eval MERCI

* `./bin/eval_merci --dataset <dataset name> --num_partition <# of partitions> --memory_ratio <size of memoization table> -c <# of threads> -r <# of repeats>`

## Eval Baseline

* `./bin/eval_baseline --dataset <dataset name> -c <# of threads> -r <# of repeats>`

The baseline supports opt-in application-defined REGENT regions. See
[MERCI zoning](../../docs/merci_regions.md) for allocation semantics,
configuration, timing, and hardware-free checks. `make test` builds all three
evaluation binaries and runs those checks without NUMA migration or PEBS.


## Eval Remapped

* `./bin/eval_remapped_only --dataset <dataset name> --num_partition <#of partitions> -c <# of threads> -r <# of repeats>`
