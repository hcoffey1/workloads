# seq_slope_bench

A tiny microbenchmark that issues sequential memory accesses at a configurable slope (addresses per unit time). When plotted with x=time and y=address, the slope parameter controls how quickly the address advances.

## Build

```bash
cd seq_slope_bench
make -j$(nproc)
```

## Run

```bash
./seq_slope_bench \
  --size-mb 512 \
  --stride 4096 \
  --duration-ms 20000 \
  --slope 8000
```

Options:
- `--bytes N` or `--size-mb M`: buffer size (default 512 MiB)
- `--stride N`: stride in bytes between touches (default 4096)
- `--duration-ms N`: run length in milliseconds (default 20000)
- `--threads N`: number of worker threads (default 1; scripts default to `$(nproc)`)
- `--slope N`: target stride advances per millisecond (default 8000; smaller values increase reuse before advancing)
- `--no-prefault`: skip prefaulting
- `--read-only`: issue loads instead of store increments

Output reports the configured slope, achieved slope, bytes touched, and GiB/s so you can align the slope to the desired access intensity.
