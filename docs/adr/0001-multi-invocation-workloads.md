# ADR 0001: Multi-invocation workloads

Status: **Accepted** (2026-06-24)

## Context

`run.sh` historically ran each workload as exactly **one tracked invocation** per
iteration: the wrapper `exec`s the binary, and the per-PID trackers (DAMON
`damo record $pid`, `numastat -p $pid`) attach to that single PID. This is the whole
reason the SPEC integration was restricted to single-invocation benchmarks — DAMON and
numastat cannot follow across `exec` boundaries, so a multi-command shell wrapper would
leave them watching the near-empty wrapper, not the benchmark
(see `docs/spec2017_integration.md`).

Several SPEC CPU2017 benchmarks are intrinsically **multi-invocation**: their refrate run
is several independent binary launches. `503.bwaves_r` is the motivating case — four
independent, long, high-bandwidth grid solves (`bwaves_1`..`bwaves_4`) driven by SPEC's
`control` file. We want bwaves (a strong memory-intensive Fortran workload) available with
the same instrumentation quality as every other workload.

## Decision

Generalize the harness so **any** workload can declare N sub-invocations, rather than
special-casing bwaves:

- A suite optionally defines `invocations_<suite>(workload)`, which echoes
  space/newline-separated **invocation labels**. `run.sh`'s `get_invocation_labels`
  accessor returns them, or empty when the hook is absent.
- `run_instrumented` brackets the workload with a single `sys_init`/`sys_cleanup`, then
  loops once per label: `export CURRENT_INVOCATION_LABEL=$label` → `run_tracked_invocation`
  (the per-invocation attach→track→detach core) → `unset`. No labels ⇒ a single unlabelled
  invocation.
- `CURRENT_INVOCATION_LABEL` is woven into every per-run filename (workload outputs,
  numastat, DAMON, PEBS), so each sub-invocation is **fully and independently tracked**.
- `start_numastat`/`stop_numastat` move inside the per-invocation core (numastat previously
  stopped only in `sys_cleanup`); `sys_cleanup`'s `stop_numastat` stays as a guarded safety
  net.

Workloads that declare nothing run exactly once with an empty label — byte-for-byte
identical filenames and behavior to before (full back-compat).

## Alternatives considered

1. **One instrument/numastat capture spanning all sub-invocations.** Rejected: the captures
   would blur four distinct solves into one timeline, losing per-solve alignment, and a
   single `damo record`/numastat still cannot follow across the four `exec`s anyway.
2. **Keep excluding multi-invocation benchmarks.** Rejected: leaves bwaves (and the whole
   perlbench/gcc/x264/xz class) permanently unavailable.
3. **Special-case bwaves in `spec.sh` only.** Rejected: the looping/labelling logic lives in
   `run.sh`, so a spec-only hack would not actually solve per-PID tracking and wouldn't
   generalize to other suites.

## Consequences

- **Trade-off accepted:** each sub-invocation pays its own instrument start/stop cycle
  (per-invocation PEBS is safe — `start_pebs`/`stop_pebs` create and remove their own FIFO).
  `sys_init`/`sys_cleanup` (cache drop, ASLR toggle) remain **once per workload**, preserving
  current timing semantics — there is no per-sub-invocation cache drop.
- The documented "excluded multi-invocation" class becomes a first-class capability; bwaves
  is its first user (`SPEC_SUBRUNS[bwaves]="bwaves_1 bwaves_2 bwaves_3 bwaves_4"`).
- This changes the core `run.sh` orchestration contract (the three former orchestrators
  `run_with_pebs`/`run_with_damon`/`run_without_instrumentation` collapse into
  `run_tracked_invocation` + `run_instrumented`), which is why it warrants an ADR.
- **Per-sub-run output isolation (for analysis tooling).** Some downstream tools (the arms
  characterization harness) write *fixed-name* artifacts — `regent_hot_profiles.csv`,
  `regent_vis_*.csv` — that are truncated at each process start and would go last-run-wins
  across sub-invocations, while the label-prefixed ones (`*_profiledump.txt`, `*_birch.txt`)
  keep all N. To keep each sub-run's artifact set complete and mutually consistent, when the
  caller sets `REGENT_VIS_DIR` the per-invocation loop redirects `OUTPUT_DIR` /
  `REGENT_VIS_DIR` / `BIRCH_OUTPUT` into a per-label subdir `<OUTPUT_DIR>/<label>/`. Plain
  runs (no `REGENT_VIS_DIR`) keep the flat, per-label filenames in `OUTPUT_DIR` unchanged —
  they have no fixed-name artifacts to collide. `INVOCATION_LIMIT` (first N sub-invocations;
  0 = all) lets a caller cap the loop (e.g. to a single representative sub-run).
- **Out of scope:** combining/post-processing the per-sub-invocation captures into a single
  per-workload view.
