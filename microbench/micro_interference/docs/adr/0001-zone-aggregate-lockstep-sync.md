# Zone-aggregate lockstep barrier for the sync feature

## Context

The sync feature lets the zipfian and sequential zones synchronize after a fixed
amount of work, modeling a BSP-style workload where the faster zone stalls for
the slower one. The obvious implementation — a per-thread barrier across all
worker threads — is unworkable here: the sequential zone's threads start
staggered (`--seq-delay`, `--seq-time-offset`), so thread *t* begins at
`t * time_offset`. A per-thread barrier would (a) deadlock during the multi-tens-
of-seconds ramp while waiting for threads that haven't started, and (b) collapse
the deliberate per-thread "echo" the stagger exists to create.

## Decision

The barrier is **zone-level on aggregate access counts**, not per-thread. Each
zone's `completed_rounds = floor(aggregate_accesses / zone_N)`; a worker stalls
(busy-spin with `_mm_pause()`, polling `global_stop`) while
`my_zone_completed > partner_completed`. Rounds advance in lockstep (max one
round ahead). N is set per zone via `--seq-sync` / `--zipf-sync` with decimal
suffixes (`1k`=1e3, `2m`=2e6, `4g`=4e9).

To keep the barrier safe and simple, sync **rejects asymmetric configurations**:
when enabled it requires both zones present (`--zipf-region-mb > 0`,
`--seq-threads >= 1`, `--zipf-threads >= 1`) and forbids per-zone
`--seq-runtime`/`--zipf-runtime`. With no early worker exit, the stall condition
never needs live-worker tracking and cannot dead-stall a surviving zone.

Delays/stagger remain legal: a delayed-but-launched worker is always coming, so
the ramp case waits correctly instead of deadlocking.

## Consequences

- Stall time is meaningful only as **per-zone wall-clock** (the whole zone stalls
  together); it is reported that way, not summed across threads.
- `--sync-rounds K` adds a fixed-work exit (stop when both zones complete K
  rounds), with `--duration` retained as a safety cap.
- Setting only one of `--seq-sync`/`--zipf-sync`, or pairing sync with a per-zone
  runtime or a disabled zone, is a hard error rather than a silently-degraded run.
