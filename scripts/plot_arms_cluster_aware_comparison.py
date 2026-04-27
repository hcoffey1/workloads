#!/usr/bin/env python3
"""Comparison plots for ARMS cluster-aware vs baseline trial times.

Supports both single-size and multi-size sweep results.

Usage:
    python3 plot_arms_cluster_aware_comparison.py <results_dir>

Expects `<results_dir>/iteration_times.csv` with columns:
    config,iteration,trial,trial_time_seconds
    (optionally: fast_mem, fast_mem_gb for multi-size sweeps)

Single-size output:
    <results_dir>/comparison.png / .pdf

Multi-size output:
    <results_dir>/comparison_<size>.png / .pdf   (per-size bar charts)
    <results_dir>/scaling.png / .pdf              (line plot across sizes)
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns


def setup_style() -> None:
    sns.set_theme(style="whitegrid")
    plt.rcParams.update({"figure.dpi": 100, "font.size": 11})


def load_data(results_dir: Path) -> pd.DataFrame:
    csv_path = results_dir / "iteration_times.csv"
    if not csv_path.exists():
        sys.exit(f"ERROR: {csv_path} not found")
    df = pd.read_csv(csv_path)
    if df.empty:
        sys.exit(f"ERROR: {csv_path} has no data rows")
    return df


def is_multi_size(df: pd.DataFrame) -> bool:
    return "fast_mem" in df.columns and df["fast_mem"].nunique() > 1


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    stats = (
        df.groupby("config")["trial_time_seconds"]
        .agg(["mean", "std", "count"])
        .rename(columns={"count": "N"})
        .reset_index()
    )
    order = ["baseline", "cluster_aware"]
    stats["__order"] = stats["config"].apply(
        lambda c: order.index(c) if c in order else len(order)
    )
    stats = stats.sort_values("__order").drop(columns="__order").reset_index(drop=True)
    return stats


def plot_bar_chart(
    stats: pd.DataFrame, results_dir: Path, suffix: str = "", title_extra: str = ""
) -> None:
    """Produce a single bar chart comparing baseline vs cluster_aware."""
    configs = stats["config"].tolist()
    means = stats["mean"].to_numpy()
    stds = stats["std"].fillna(0.0).to_numpy()
    ns = stats["N"].to_numpy()

    palette = sns.color_palette("muted")
    colors = []
    for cfg in configs:
        if cfg == "baseline":
            colors.append("#999999")
        elif cfg == "cluster_aware":
            colors.append(palette[2])
        else:
            colors.append(palette[0])

    fig, ax = plt.subplots(figsize=(6, 5))
    x = np.arange(len(configs))
    ax.bar(
        x,
        means,
        yerr=stds,
        color=colors,
        edgecolor="black",
        linewidth=0.8,
        capsize=6,
    )
    ax.set_xticks(x)
    ax.set_xticklabels(configs)
    ax.set_ylabel("Trial time (s)")
    n_repr = int(ns.max()) if len(ns) else 0
    title = f"gapbs bc — ARMS cluster-aware vs baseline (N={n_repr} trials each)"
    if title_extra:
        title += f"\n{title_extra}"
    ax.set_title(title)

    # Annotate signed relative delta above the cluster_aware bar.
    if "baseline" in configs and "cluster_aware" in configs:
        base_row = stats[stats["config"] == "baseline"].iloc[0]
        ca_row = stats[stats["config"] == "cluster_aware"].iloc[0]
        base_mean = float(base_row["mean"])
        ca_mean = float(ca_row["mean"])
        if base_mean > 0:
            delta_pct = (ca_mean - base_mean) / base_mean * 100.0
            annot_color = "green" if delta_pct < 0 else "red"
            sign = "-" if delta_pct < 0 else "+"
            ca_idx = configs.index("cluster_aware")
            ca_std = float(ca_row["std"]) if not np.isnan(ca_row["std"]) else 0.0
            y_anchor = ca_mean + ca_std
            ax.annotate(
                f"{sign}{abs(delta_pct):.1f}%",
                xy=(ca_idx, y_anchor),
                xytext=(0, 10),
                textcoords="offset points",
                ha="center",
                fontsize=12,
                fontweight="bold",
                color=annot_color,
            )
            ax.annotate(
                f"N={int(ca_row['N'])} trials",
                xy=(ca_idx, y_anchor),
                xytext=(0, 26),
                textcoords="offset points",
                ha="center",
                fontsize=9,
                color="#555555",
            )

    if len(means):
        tops = means + stds
        ymax = float(tops.max()) * 1.20
        ax.set_ylim(0, ymax)

    fig.tight_layout()

    name = f"comparison_{suffix}" if suffix else "comparison"
    png_path = results_dir / f"{name}.png"
    pdf_path = results_dir / f"{name}.pdf"
    fig.savefig(png_path, dpi=150, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Wrote {png_path}")
    print(f"Wrote {pdf_path}")


def plot_scaling(df: pd.DataFrame, results_dir: Path) -> None:
    """Line plot: mean trial time vs fast memory size, one line per config."""
    stats = (
        df.groupby(["fast_mem_gb", "config"])["trial_time_seconds"]
        .agg(["mean", "std", "count"])
        .rename(columns={"count": "N"})
        .reset_index()
    )
    stats["std"] = stats["std"].fillna(0.0)
    stats = stats.sort_values("fast_mem_gb")

    palette = sns.color_palette("muted")
    cfg_style = {
        "baseline": {"color": "#999999", "marker": "s", "label": "Baseline"},
        "cluster_aware": {"color": palette[2], "marker": "o", "label": "Cluster-Aware"},
    }

    fig, ax = plt.subplots(figsize=(10, 6))

    for cfg in ["baseline", "cluster_aware"]:
        sub = stats[stats["config"] == cfg]
        if sub.empty:
            continue
        style = cfg_style.get(cfg, {"color": palette[0], "marker": "^", "label": cfg})
        ax.errorbar(
            sub["fast_mem_gb"],
            sub["mean"],
            yerr=sub["std"],
            label=style["label"],
            color=style["color"],
            marker=style["marker"],
            markersize=7,
            linewidth=2,
            capsize=4,
            capthick=1.5,
        )

    ax.set_xlabel("Fast memory size (GB)")
    ax.set_ylabel("Mean trial time (s)")
    ax.set_title("gapbs bc — ARMS cluster-aware vs baseline across memory tier sizes")
    ax.legend(frameon=True)

    # Set x-ticks to the actual sizes tested
    sizes = sorted(stats["fast_mem_gb"].unique())
    ax.set_xticks(sizes)
    ax.set_xticklabels([f"{s:g}" for s in sizes], rotation=45 if len(sizes) > 10 else 0)

    fig.tight_layout()

    png_path = results_dir / "scaling.png"
    pdf_path = results_dir / "scaling.pdf"
    fig.savefig(png_path, dpi=150, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Wrote {png_path}")
    print(f"Wrote {pdf_path}")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <results_dir>")

    results_dir = Path(sys.argv[1]).resolve()
    if not results_dir.is_dir():
        sys.exit(f"ERROR: {results_dir} is not a directory")

    setup_style()
    df = load_data(results_dir)

    if is_multi_size(df):
        # Multi-size sweep: per-size bar charts + scaling line plot
        print("Detected multi-size sweep data.\n")

        # Per-size bar charts
        for fast_mem, group in df.groupby("fast_mem"):
            print(f"--- {fast_mem} ---")
            stats = summarize(group)
            for _, row in stats.iterrows():
                std = 0.0 if pd.isna(row["std"]) else float(row["std"])
                print(
                    f"  {row['config']:15s} N={int(row['N']):4d}  "
                    f"mean={row['mean']:.5f}s  std={std:.5f}s"
                )
            plot_bar_chart(
                stats,
                results_dir,
                suffix=str(fast_mem),
                title_extra=f"Fast memory: {fast_mem}",
            )

        # Scaling line plot
        print("\n--- Scaling plot ---")
        plot_scaling(df, results_dir)
    else:
        # Single-size: original behavior
        stats = summarize(df)
        print("Per-config summary (from iteration_times.csv):")
        for _, row in stats.iterrows():
            std = 0.0 if pd.isna(row["std"]) else float(row["std"])
            print(
                f"  {row['config']:15s} N={int(row['N']):4d}  "
                f"mean={row['mean']:.5f}s  std={std:.5f}s"
            )
        plot_bar_chart(stats, results_dir)


if __name__ == "__main__":
    main()
