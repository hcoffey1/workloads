#!/usr/bin/env python3
"""
Case study: Group addresses at 1 GB boundaries, sort groups by total
access count (descending), and plot the cumulative sum of accesses.

X-axis: number of 1 GB groups (ranked by hotness)
Y-axis: % of total accesses

Accepts one or two .samples/.dat files.  When two are given the script
expects one VA file and one PA file and plots both curves together.

Usage:
    python va_pa_case_study.py <file1> [file2] [-o output.png]
"""

import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def parse_samples(path: str, bucket_bytes: int):
    """
    Parse a PEBS samples file.

    Parameters
    ----------
    path         : str   path to the samples file
    bucket_bytes : int   grouping granularity in bytes

    Returns
    -------
    addr_type : str   ('VA' or 'PA')
    groups    : dict   {bucket_start_addr: total_count}
    """
    addr_type = "unknown"
    groups: dict[int, int] = {}

    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                # Header line like "# VA" or "# PA"
                addr_type = line.lstrip("# ").strip()
                continue

            parts = line.split()
            addr = int(parts[0], 16)
            # Last value in the cumulative series is the total count
            total_count = int(parts[-1])

            # Group by bucket boundary
            bucket = (addr // bucket_bytes) * bucket_bytes
            groups[bucket] = groups.get(bucket, 0) + total_count

    return addr_type, groups


def cumsum_curve(groups: dict[int, int]):
    """
    Sort groups descending by count, compute cumulative percentage.

    Returns
    -------
    x : np.ndarray  (1, 2, …, n_groups)
    y : np.ndarray  (cumulative % of total accesses)
    """
    counts = np.array(sorted(groups.values(), reverse=True), dtype=np.float64)
    total = counts.sum()
    if total == 0:
        return np.array([0]), np.array([0.0])
    cumulative = np.cumsum(counts) / total * 100.0
    x = np.arange(1, len(cumulative) + 1)
    return x, cumulative


def buckets_to_threshold(groups: dict[int, int], threshold_pct: float = 80.0) -> int:
    """Return the number of buckets (ceiling) needed to reach/exceed
    *threshold_pct* % of total accesses."""
    counts = np.array(sorted(groups.values(), reverse=True), dtype=np.float64)
    total = counts.sum()
    if total == 0:
        return 0
    cumulative = np.cumsum(counts) / total * 100.0
    # First index where cumulative >= threshold
    idx = np.searchsorted(cumulative, threshold_pct, side="left")
    return int(idx + 1)  # 1-based count


def plot(curves, output: str | None, bucket_label: str = "1 GB",
         bar_data: list | None = None, threshold_pct: float = 80.0,
         bucket_gb_size: float = 1.0):
    """
    Parameters
    ----------
    curves    : list of (label, (x, y))
    bar_data  : list of (label, n_buckets)  — for the bar chart
    """
    n_plots = 1 + (1 if bar_data else 0)
    fig, axes = plt.subplots(1, n_plots, figsize=(7 * n_plots, 5))
    if n_plots == 1:
        axes = [axes]

    # --- Cumulative curve ---
    ax = axes[0]
    for label, (x, y) in curves:
        ax.plot(x, y, marker="o", markersize=3, linewidth=1.5, label=label)

    ax.set_xlabel(f"Number of {bucket_label} groups (ranked by hotness)")
    ax.set_ylabel("Cumulative % of total accesses")
    ax.set_title(f"Access Density: {bucket_label} Grouping")
    ax.set_ylim(0, 105)
    ax.axhline(y=threshold_pct, color="red", linestyle="--", linewidth=0.8,
               label=f"{threshold_pct:g}% threshold")
    ax.axhline(y=100, color="grey", linestyle="--", linewidth=0.7)
    ax.legend()
    ax.grid(True, alpha=0.3)

    # --- Bar chart ---
    if bar_data:
        ax2 = axes[1]
        labels = [d[0] for d in bar_data]
        vals = [d[1] for d in bar_data]
        gb_vals = [v * bucket_gb_size for v in vals]
        colors = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728"][:len(vals)]

        # Determine bar positions: VA/PA bars on the left, ratio on the right
        x_pos = np.arange(len(labels))
        bars = ax2.bar(x_pos, gb_vals, color=colors, edgecolor="black", width=0.5)
        for bar, gb in zip(bars, gb_vals):
            ax2.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.3,
                     f"{gb:g} GB", ha="center", va="bottom", fontweight="bold")
        ax2.set_ylabel(f"GB needed ({bucket_label} buckets)")
        ax2.set_title(f"Memory for {threshold_pct:g}% of accesses")
        ax2.set_ylim(0, max(gb_vals) * 1.4 if gb_vals else 1)
        ax2.grid(True, axis="y", alpha=0.3)

        # If we have exactly 2 entries (VA and PA), add a ratio bar on a second y-axis
        if len(bar_data) == 2:
            # Find which is VA and which is PA
            va_gb = pa_gb = None
            for lbl, n in bar_data:
                g = n * bucket_gb_size
                if lbl.upper() == "VA":
                    va_gb = g
                elif lbl.upper() == "PA":
                    pa_gb = g
            if va_gb and pa_gb:
                ratio = pa_gb / va_gb
                ax3 = ax2.twinx()
                ratio_x = len(labels)  # position to the right of existing bars
                ratio_bar = ax3.bar(ratio_x, ratio, color="#2ca02c",
                                    edgecolor="black", width=0.5, alpha=0.8)
                ax3.text(ratio_x, ratio + 0.02,
                         f"{ratio:.2f}x", ha="center", va="bottom",
                         fontweight="bold", color="#2ca02c")
                ax3.set_ylabel("PA / VA ratio", color="#2ca02c")
                ax3.tick_params(axis="y", labelcolor="#2ca02c")
                ax3.set_ylim(0, max(ratio * 1.5, 1.5))

                # Fix x-axis ticks to include the ratio bar
                all_labels = labels + ["PA/VA"]
                ax2.set_xticks(list(range(len(all_labels))))
                ax2.set_xticklabels(all_labels)
            else:
                ax2.set_xticks(x_pos)
                ax2.set_xticklabels(labels)
        else:
            ax2.set_xticks(x_pos)
            ax2.set_xticklabels(labels)

    fig.tight_layout()

    if output:
        fig.savefig(output, dpi=200)
        print(f"Saved plot to {output}")
    else:
        plt.show()


def main():
    parser = argparse.ArgumentParser(
        description="Plot cumulative access density by 1 GB groups."
    )
    parser.add_argument(
        "files",
        nargs="+",
        help="One or two .samples/.dat files (VA and/or PA)",
    )
    parser.add_argument(
        "-o", "--output",
        default=None,
        help="Output image path (default: display interactively)",
    )
    parser.add_argument(
        "-b", "--bucket-gb",
        type=float,
        default=1.0,
        help="Bucket size in GB for grouping addresses (default: 1.0)",
    )
    args = parser.parse_args()

    if len(args.files) > 2:
        print("Error: provide at most 2 files (one VA, one PA).", file=sys.stderr)
        sys.exit(1)

    bucket_bytes = int(args.bucket_gb * (1 << 30))
    bucket_label = f"{args.bucket_gb:g} GB"
    threshold_pct = 80.0

    curves = []
    bar_data = []
    for fpath in args.files:
        addr_type, groups = parse_samples(fpath, bucket_bytes)
        x, y = cumsum_curve(groups)
        n_groups = len(groups)
        total = sum(groups.values())
        n_for_threshold = buckets_to_threshold(groups, threshold_pct)
        label = f"{addr_type} ({n_groups} groups, {total:,} samples)"
        print(f"{fpath}: type={addr_type}, {n_groups} {bucket_label} groups, "
              f"{total:,} total samples, {n_for_threshold} buckets for {threshold_pct:g}%")
        curves.append((label, (x, y)))
        bar_data.append((addr_type, n_for_threshold))

    plot(curves, args.output, bucket_label=bucket_label,
         bar_data=bar_data, threshold_pct=threshold_pct,
         bucket_gb_size=args.bucket_gb)


if __name__ == "__main__":
    main()
