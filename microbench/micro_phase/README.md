# Microbenchmark: Phase-Toggled Hotsets

## Rationale
ARMS scores pages using frequency-biased EWMAs. When the working set shifts rapidly between disjoint regions, the historical frequency keeps both regions looking hot at the same time. That stalls demotions/promotions and leaves fast-tier space polluted with pages from the prior phase. An LRU-style policy that leans on recent touches (recency) should react faster and prefer the currently active phase.

## Workload shape
- Two regions `A` and `B`, each sized near the fast-tier capacity (e.g., 1–3 GB each when fast tier is ~2–4 GB).
- Execution alternates phases: sweep A for a few iterations, then sweep B for the same count, repeating many cycles.
- Access stride is 4 KB so the MMU accessed bit is set per base page; using `madvise(..., MADV_HUGEPAGE)` encourages huge pages if available.
- ARMS will accumulate EWMA history for both regions and hesitate to demote the prior phase; a recency-driven LRU should drop the stale phase quickly and keep the current one resident.

## How to build
From the repo root:
```
g++ -O2 -std=c++11 microbenchmark/phase_toggle.cpp -o microbenchmark/phase_toggle
```

## How to run
```
# args: <num_regions> <region_mb> <stride_bytes> <phase_iters> <cycles>
./microbenchmark/phase_toggle 4 2048 4096 4 12
```
- Use `REGENT_REGIONS` to pin this process to the ARMS policy region and compare against LRU/LRU-RECENCY variants.
- Expect ARMS to retain pages from the previous phase longer, overshooting fast-tier capacity or delaying promotions, while LRU-style policies pivot faster between A and B.
