# OGB (Open Graph Benchmark) Integration

GraphSAGE mini-batch training over OGB node-property-prediction graphs, added as a
memory-intensive workload with **multiple unique concurrent memory access patterns**.

## Why it's in the suite

A single run interleaves three qualitatively different access patterns:

1. **Sparse, pointer-chasing topology walks** — `NeighborLoader` neighbor sampling
   walks the CSR `rowptr`/`col` arrays (random access).
2. **Random feature-row gathers** — pulling sampled nodes' rows out of the dense `x`
   feature matrix (the classic GNN bandwidth bottleneck).
3. **Dense streaming GEMM/SpMM** — the two `SAGEConv` layers' forward/backward
   (cache-friendly, compute-bound).

This makes it a stronger fit for studying mixed/concurrent patterns than the
single-pattern gapbs kernels.

## Files

- `ogb/ogb_gnn.py` — the workload. Env-driven and CPU-pinned.
- `scripts/workloads/ogb.sh` — harness integration (`config_/build_/run_/clean_ogb`).

## Workloads (`-w`)

| `-w` | Dataset | Scale | Notes |
|---|---|---|---|
| `products` | ogbn-products | 2.4M nodes / 61M edges / 100-dim feats (~2–3 GB) | Default. ~1.4 GB download. |
| `papers100M` | ogbn-papers100M | 111M nodes / 1.6B edges / 128-dim feats (~100 GB+) | Opt-in. ~60 GB download, needs ~100 GB+ RAM. |

## Key design decisions

- **CPU-pinned** (`device='cpu'`, not GPU-if-available). The harness measures host
  NUMA/memory-tiering behaviour (`numactl`, `bwmon`, HeMem); GPU execution would move
  the feature tensors off-host and defeat the measurement.
- **`num_workers=0` by default** (deviates from the upstream `4`). PyTorch DataLoader
  workers are *processes* (GIL), which escape `/usr/bin/time -v` RSS accounting and the
  harness PID tracking. `num_workers=0` runs everything as one OMP-threaded process —
  consistent with gapbs/faiss — and still exercises all three access patterns; it only
  drops the temporal sampler↔compute overlap. Opt back in with `OGB_NUM_WORKERS>0`
  (bandwidth via system-wide `bwmon` stays valid; RSS then undercounts).
- **Dedicated `ogb` conda env** (not the shared `dataVis` plotting env) for the heavy
  CPU-only torch + torch_geometric + ogb stack. The wrapper execs the env's python
  directly — no `conda activate` needed.

## Tunables (env vars)

| Var | Default | Effect |
|---|---|---|
| `OGB_EPOCHS` | `3` | Training epochs |
| `OGB_BATCH_SIZE` | `1024` | Seed nodes per batch |
| `OGB_NUM_WORKERS` | `0` | DataLoader sampler processes (0 = in-process) |
| `OGB_NUM_THREADS` | `8` | `OMP_NUM_THREADS`/`MKL_NUM_THREADS` for intra-op pool |
| `OGB_CONDA_ENV` | `ogb` | Conda env name |
| `OGB_DATA_ROOT` | `ogb/dataset` | Dataset download/cache root |

## Build

`build_ogb` is idempotent (run on every `run.sh` invocation):
1. Creates the `ogb` conda env (python 3.10) if missing and pip-installs CPU-only
   torch, then matching `pyg-lib`/`torch-scatter`/`torch-sparse` wheels from
   `data.pyg.org`, plus `torch_geometric` and `ogb`.
2. Downloads + processes the selected dataset *outside* the timed run, so only the
   training loop is measured.

## Example

```bash
./run.sh -b ogb -w products -o results/ogb_products
OGB_EPOCHS=5 ./run.sh -b ogb -w products -o results/ogb_products_5ep
```
