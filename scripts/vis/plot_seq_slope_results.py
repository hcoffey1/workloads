#!/usr/bin/env python3
"""Parse seq_slope_bench results and produce throughput plots.

Two plot sets are emitted:
1) Fix fast size; x-axis is slope; one line per policy.
2) Fix slope; x-axis is fast size; one line per policy.

Source data is expected under results_seq_slope_bench/, with
subdirectories named results_seq_slope_bench_<FASTSIZE>_slope_<SLOPE>/,
containing per-policy folders like results_arms/ with *_stdout.txt files.
"""
from __future__ import annotations

import argparse
import pathlib
import re
from statistics import mean
from typing import Dict, Iterable, Tuple

import matplotlib.pyplot as plt

DIR_RE = re.compile(r"results_seq_slope_bench_(?P<size>[^_]+)_slope_(?P<slope>[^/]+)")
THROUGHPUT_RE = re.compile(r"throughput_GiB_per_s min/avg/max=([0-9.+-eE]+)/([0-9.+-eE]+)/([0-9.+-eE]+)")


def parse_fast_size(label: str) -> float:
    label = label.strip().lower()
    if label.endswith("g"):
        label = label[:-1]
    return float(label)


def collect_results(root: pathlib.Path) -> Dict[Tuple[float, float], Dict[str, float]]:
    data: Dict[Tuple[float, float], Dict[str, float]] = {}

    for entry in root.iterdir():
        if not entry.is_dir():
            continue
        match = DIR_RE.match(entry.name)
        if not match:
            continue

        fast_size = parse_fast_size(match.group("size"))
        slope = float(match.group("slope"))
        combo_key = (fast_size, slope)
        policy_avgs: Dict[str, float] = {}

        for policy_dir in entry.iterdir():
            if not policy_dir.is_dir() or not policy_dir.name.startswith("results_"):
                continue
            policy = policy_dir.name.replace("results_", "", 1)
            per_iter: list[float] = []

            for stdout_file in policy_dir.glob("*_stdout.txt"):
                text = stdout_file.read_text(errors="ignore")
                for line in text.splitlines():
                    m = THROUGHPUT_RE.search(line)
                    if m:
                        per_iter.append(float(m.group(2)))
                        break

            if per_iter:
                policy_avgs[policy] = mean(per_iter)

        if policy_avgs:
            data[combo_key] = policy_avgs

    return data


def plot_lines(x_values: Iterable[float], series: Dict[str, Dict[float, float]], *, xlabel: str, title: str, outpath: pathlib.Path) -> None:
    fig, ax = plt.subplots(figsize=(8, 5))
    for policy, points in sorted(series.items()):
        xs = []
        ys = []
        for x in sorted(x_values):
            if x in points:
                xs.append(x)
                ys.append(points[x])
        if xs:
            ax.plot(xs, ys, marker="o", label=policy)

    ax.set_xlabel(xlabel)
    ax.set_ylabel("Average per-thread throughput (GiB/s)")
    ax.set_title(title)
    ax.grid(True, linestyle=":", alpha=0.6)
    ax.legend()
    outpath.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(outpath)
    plt.close(fig)


def build_plots(data: Dict[Tuple[float, float], Dict[str, float]], outdir: pathlib.Path) -> None:
    sizes = sorted({size for size, _ in data})
    slopes = sorted({slope for _, slope in data})

    # Fix fast size, sweep slope.
    for size in sizes:
        series: Dict[str, Dict[float, float]] = {}
        for slope in slopes:
            entry = data.get((size, slope))
            if not entry:
                continue
            for policy, throughput in entry.items():
                series.setdefault(policy, {})[slope] = throughput

        if series:
            outpath = outdir / f"fastsize_{size:g}G_vs_slope.png"
            title = f"Fast size {size:g}G: throughput vs slope"
            plot_lines(slopes, series, xlabel="Slope (stride advances/ms)", title=title, outpath=outpath)

    # Fix slope, sweep fast size.
    for slope in slopes:
        series: Dict[str, Dict[float, float]] = {}
        for size in sizes:
            entry = data.get((size, slope))
            if not entry:
                continue
            for policy, throughput in entry.items():
                series.setdefault(policy, {})[size] = throughput

        if series:
            outpath = outdir / f"slope_{slope:g}_vs_fastsize.png"
            title = f"Slope {slope:g}: throughput vs fast size"
            plot_lines(sizes, series, xlabel="Fast size (GiB)", title=title, outpath=outpath)


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot seq_slope_bench throughput summaries")
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path("results_seq_slope_bench"), help="Root directory containing result bundles")
    parser.add_argument("--outdir", type=pathlib.Path, default=pathlib.Path("plots_seq_slope_bench"), help="Output directory for plots")
    args = parser.parse_args()

    data = collect_results(args.root)
    if not data:
        raise SystemExit(f"No results found under {args.root}")

    build_plots(data, args.outdir)
    print(f"Wrote plots to {args.outdir}")


if __name__ == "__main__":
    main()
