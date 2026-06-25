# CONTEXT — domain glossary

Load-bearing terms for this benchmarking suite. These are the words the harness code and
docs use precisely; keep usage consistent with the definitions here.

## Glossary

### Invocation
A single launch of a workload binary that the harness tracks as one PID: the wrapper
`exec`s the binary, and DAMON / numastat / PEBS attach to that PID for its lifetime. The
unit of "one tracked run." Most workloads are exactly one invocation per iteration.

### Invocation label
A short tag identifying one sub-invocation of a multi-invocation workload (e.g.
`bwaves_1`). When set (`CURRENT_INVOCATION_LABEL`), it is woven into every per-run
filename — workload outputs (`spec_bwaves_1_*`), numastat (`numastat_bwaves_1_*`), DAMON
(`..._bwaves_1_..._damon.dat`), PEBS (`..._bwaves_1_..._samples.dat`) — so each
sub-invocation's captures are independent. An empty label leaves all names unchanged.

### Single-invocation workload
A workload that runs as exactly one invocation per iteration. It declares no
sub-invocations, so the harness runs it once with an empty invocation label. This is the
default and the original behavior of the harness.

### Multi-invocation workload
A workload whose ref run is several independent binary invocations (e.g. SPEC
`503.bwaves_r` = 4 grid solves). It declares its sub-invocations via the suite hook
`invocations_<suite>(workload)`, which echoes the invocation labels. `run.sh` then loops
its attach→track→detach cycle once per label, each sub-invocation **fully and
independently tracked** (separate instrument + numastat capture, separate output files).
`sys_init`/`sys_cleanup` still bracket the whole workload, not each sub-invocation. See
`docs/adr/0001-multi-invocation-workloads.md`.
