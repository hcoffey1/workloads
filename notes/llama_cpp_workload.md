# llama.cpp Workload – Reference Guide

## Overview

[llama.cpp](https://github.com/ggerganov/llama.cpp) is a high-performance C/C++
inference engine for Large Language Models (LLMs).  It loads models in the **GGUF**
format (a quantised, single-file container) and runs them entirely on CPU
(or optionally GPU).  For our memory-management experiments the interesting
property is that model weights, KV-cache, and scratch buffers all live in
user-space memory, giving us a realistic, memory-intensive workload.

---

## Workload Binaries

### `llama-bench`
The **throughput / latency benchmark** tool.  It runs two phases in a loop:

| Phase | What it measures |
|---|---|
| **Prompt processing (pp)** | How fast the model can *prefill* a prompt of `n_prompt` tokens (batched matrix multiplications).  Reported as **tokens/s**. |
| **Text generation (tg)** | How fast the model can *generate* `n_gen` tokens one-by-one (autoregressive decoding).  Reported as **tokens/s**. |

Each phase is repeated `--repetitions` times and statistics are printed.
This is the default workload in our script because it produces deterministic,
repeatable throughput numbers with no external dependencies (no dataset, no
interactive input).

### `llama-cli`
A **command-line chat / completion** interface.  You give it a prompt
(`-p "..."`) and it generates a continuation.  Useful for interactive testing
or generating a fixed amount of text, but less suited for automated
benchmarking because output length can vary with sampling parameters.

### `llama-perplexity`
Evaluates the model's **perplexity** on a text dataset (`-f dataset.txt`).
Perplexity is an information-theoretic measure of how well the model predicts
the next token — lower is better.  This workload reads the entire dataset
sequentially, splits it into context-sized chunks, and computes the
cross-entropy loss.  It is very memory- and compute-intensive but requires a
dataset file.

---

## Key Arguments Explained

### Model & Hardware

| Flag | Variable | Meaning |
|---|---|---|
| `-m, --model` | `LLAMA_MODEL` | Path to the `.gguf` model file.  The model is loaded entirely into RAM (unless mmap is on). |
| `-t, --threads` | `LLAMA_THREADS` | Number of CPU threads for matrix operations.  Set to the number of physical cores on the NUMA node you bind to. |
| `-ngl, --n-gpu-layers` | `LLAMA_N_GPU_LAYERS` | How many transformer layers to offload to GPU.  **0 = pure CPU** — what we want for memory experiments. |

### Memory Mapping

| Flag | Variable | Meaning |
|---|---|---|
| `-mmp, --mmap` | `LLAMA_MMAP` | **0 = disabled (default in our script), 1 = enabled**.  When mmap is **enabled**, the model file is memory-mapped: the OS lazily pages model weights in from disk on demand and can evict them under memory pressure.  When mmap is **disabled**, llama.cpp `read()`s the entire model into an allocated buffer at startup — all weights are resident immediately and managed by our memory allocator (HeMem / ARMS).  **We disable mmap so that the allocator controls placement of model weights across fast and slow memory tiers.** |

### Benchmark Parameters (`llama-bench`)

| Flag | Variable | Meaning |
|---|---|---|
| `-r, --repetitions` | `LLAMA_REPETITIONS` | Number of times each test (pp + tg) is repeated for statistical confidence. |
| `-p, --n-prompt` | `LLAMA_N_PROMPT` | Number of tokens in the synthetic prompt for the prefill phase.  Larger values stress memory bandwidth more (bigger batch matmuls). |
| `-n, --n-gen` | `LLAMA_N_GEN` | Number of tokens to generate in the decode phase.  Each token is one forward pass, so this controls how long decode runs. |
| `-b, --batch-size` | `LLAMA_BATCH_SIZE` | Maximum batch size for prompt processing.  If `n_prompt > batch_size`, the prompt is processed in chunks of this size. |
| `-ub, --ubatch-size` | `LLAMA_UBATCH_SIZE` | Micro-batch size — the inner tile for matrix multiplications.  Affects cache efficiency. |
| `-o, --output` | `LLAMA_OUTPUT_FMT` | Output format: `md` (markdown table), `csv`, `json`, `jsonl`, or `sql`. |

### Inference Parameters (`llama-cli`)

| Flag | Variable | Meaning |
|---|---|---|
| `-p, --prompt` | `LLAMA_PROMPT` | The input text prompt for generation. |
| `-c, --ctx-size` | `LLAMA_CTX_SIZE` | Context window size in tokens.  Determines the maximum sequence length and the size of the **KV-cache** (which is a significant memory consumer: `2 × n_layers × ctx_size × head_dim × n_heads × sizeof(float16)`). |

### Perplexity Parameters (`llama-perplexity`)

| Flag | Variable | Meaning |
|---|---|---|
| `-f` | `LLAMA_PPL_DATASET` | Path to a plain-text dataset file (e.g., WikiText-2).  The tool splits this into context-sized windows and evaluates perplexity. |

---

## Memory Footprint Breakdown

For a model with **P** parameters at quantisation **Q** bits:

$$\text{Model weights} \approx \frac{P \times Q}{8} \text{ bytes}$$

For example, TinyLlama 1.1B at Q4_K_M ≈ 670 MB, Llama-2 7B at Q4_K_M ≈ 4.1 GB,
Llama-2 70B at Q4_K_M ≈ 40 GB.

The **KV-cache** grows with context length:

$$\text{KV-cache} \approx 2 \times L \times C \times d_h \times n_h \times 2 \text{ bytes (fp16)}$$

where $L$ = layers, $C$ = context tokens, $d_h$ = head dimension, $n_h$ = number of KV heads.

On your **180 GB Intel Xeon** system you can comfortably run up to ~70B Q4
models with large contexts.

---

## Model Download

The script auto-downloads a model if `LLAMA_MODEL` doesn't exist on disk.
The default is **TinyLlama 1.1B Q4_K_M** (~670 MB) for fast iteration.
Override with environment variables for larger models:

```bash
# Example: Llama-2 7B Q4_K_M (~4.1 GB)
export LLAMA_MODEL_URL="https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf"
export LLAMA_MODEL="$HOME/workloads/llama.cpp/models/llama-2-7b-q4km.gguf"
```

---

## How the Workload Script Works

The script (`scripts/workloads/llama_cpp.sh`) follows the standard workload
pattern and exports four functions:

| Function | Purpose |
|---|---|
| `config_llama_cpp` | Sets all configurable parameters with sensible defaults. |
| `build_llama_cpp` | Downloads the model (if missing) and builds llama.cpp via CMake. |
| `run_llama_cpp` | Constructs the CLI arguments, creates the wrapper script, and launches the workload via `run_workload_standard` (numactl + time + cgroup). |
| `clean_llama_cpp` | Stops bwmon. |

Invoked through `run.sh`:
```bash
./run.sh -b llama_cpp -w llama-bench -o results/llama_test -r 1 --use-cgroup
```
