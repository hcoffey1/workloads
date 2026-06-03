# micro_interference

A microbenchmark that drives two concurrent memory-access generators against a
shared address space to study tiering/interference behavior. One generator walks
memory sequentially across rotating buffers; the other hits a single buffer with
a zipfian (skewed) distribution. Throughput of each is sampled over time.

## Language

**Zone**:
One of the two access-pattern generators that can meet at a sync barrier: the
**sequential zone** or the **zipfian zone**. A zone may be backed by one or more
worker threads.
_Avoid_: "region" (means a memory buffer, not a generator), "pattern", "side".

**Region**:
A single contiguous memory buffer (`struct Region`). The sequential zone owns
several regions and rotates through them on a wall-clock timer
(`--seq-phase-duration`); the zipfian zone owns exactly one region.
_Avoid_: "zone", "buffer".

**Worker**:
A thread that performs accesses on behalf of a zone (`sequential_worker`,
`zipfian_worker`). `--seq-threads` / `--zipf-threads` set how many workers back
each zone.

**Sync**:
An optional lockstep barrier between the two zones. Enabled by setting both
`--seq-sync` and `--zipf-sync` (per-zone access counts, e.g. `1k`, `2m`). The
barrier operates on each zone's *aggregate* access count, never on individual
workers.
_Avoid_: "barrier" alone (ambiguous), "lock".

**Round**:
A unit of synced work: one round of a zone = that zone's per-zone N accesses
(`completed_rounds = floor(zone_aggregate_accesses / zone_N)`). Zones advance
round-for-round in lockstep; a zone may be at most one round ahead before it
stalls.

**Stall**:
The state of a zone that has completed more rounds than its partner and is
busy-spinning (whole zone, all workers together) until the partner catches up.
Reported per zone as wall-clock blocked time.

**Sync regime**:
Which zone stalls, determined by the *sync pair* `(SEQ_SYNC, ZIPF_SYNC)` (the two
zones' accesses-per-round) relative to the zones' achievable access *rates*. A
zone stalls when it finishes its round sooner than its partner, i.e. when
`my_N / my_rate < partner_N / partner_rate`. The sequential zone typically runs
~2× the zipfian rate, so:
- **balanced** — counts in ~rate proportion (≈2:1 seq:zipf); neither zone stalls.
- **seq-stalls** — counts too equal for the rate gap (e.g. 1:1); the faster
  sequential zone finishes early and waits.
- **zipf-stalls** — sequential count much larger (e.g. 4:1), making the
  sequential zone the bottleneck; the zipfian zone waits.
Used by `sweep_micro_sync.sh` to vary the sync pair and study each tiering
policy's response. _Avoid_: "balanced" to mean equal counts — equal counts is
the seq-stalls regime here, because the rates differ.

**Runtime (ROI)**:
The benchmark's own measured run, printed as `Total Time: <s>` in the stdout
SUMMARY — the region-of-interest between `===ROI_START===` and `===ROI_END===`.
Distinct from `/usr/bin/time -v`'s "Elapsed (wall clock) time" in `_time.txt`,
which also includes the binary's fixed startup (a hardcoded `sleep(10)` before it
publishes region bounds, plus prefault) and tiering teardown — so Elapsed runs
~10s+ longer. Use **Runtime (ROI)** to compare a policy's effect on the workload;
use `_time.txt` Elapsed only when startup/teardown overhead is itself the subject.
Summarized per (policy, peak_rss) by `plot_micro_sync_summary.py` alongside the
two zones' **Stall** times.

## Relationships

- A **Zone** is driven by one or more **Workers**
- The **sequential zone** owns many **Regions**; the **zipfian zone** owns one **Region**
- **Sync** couples the two **Zones** via **Rounds**; the faster zone **Stalls** for the slower
- A **Stall** is a property of a whole **Zone**, not of individual **Workers**
- The **Sync regime** (which **Zone Stalls**) follows from the *sync pair* counts vs. the **Zones'** access rates

## Flagged ambiguities

- "region" in the original sync feature request meant **Zone** (the two barrier
  participants), not the memory-buffer `Region`. Resolved: the two synchronizing
  sides are **Zones**.
