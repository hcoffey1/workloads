#!/usr/bin/env python3
"""Comparison plots for ARMS vs Duration-Prediction policy average times.

Supports both single-size and multi-size sweep results.

Usage:
    python3 plot_duration_pred_comparison.py <results_dir>

Expects `<results_dir>/iteration_times.csv` with columns:
    fast_mem,fast_mem_gb,config,iteration,avg_time_seconds

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


CONFIGS = ["arms", "duration_pred"]
LABELS = {"arms": "ARMS", "duration_pred": "Duration-Pred"}
COLORS = {"arms": "#999999", "duration_pred": sns.color_palette("muted")[0]}
MARKERS = {"arms": "s", "duration_pred": "o"}


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
        df.groupby("config")["avg_time_seconds"]
        .agg(["mean", "std", "count"])
        .rename(columns={"count": "N"})
        .reset_index()
    )
    order = CONFIGS
    stats["__order"] = stats["config"].apply(
        lambda c: order.index(c) if c in order else len(order)
    )
    stats = stats.sort_values("__order").drop(columns="__order").reset_index(drop=True)
    return stats


def plot_bar_chart(
    stats: pd.DataFrame, results_dir: Path, suffix: str = "", title_extra: str = ""
) -> None:
    configs = stats["config"].tolist()
    means = stats["mean"].to_numpy()
    stds = stats["std"].fillna(0.0).to_numpy()
    ns = stats["N"].to_numpy()

    colors = [COLORS.get(c, sns.color_palette("muted")[2]) for c in configs]

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
    ax.set_xticklabels([LABELS.get(c, c) for c in configs])
    ax.set_ylabel("Average time (s)")
    n_repr = int(ns.max()) if len(ns) else 0
    title = f"gapbs bc -- ARMS vs Duration-Pred (N={n_repr} iterations each)"
    if title_extra:
        title += f"\n{title_extra}"
    ax.set_title(title)

    # Annotate signed relative delta above the duration_pred bar.
    if "arms" in configs and "duration_pred" in configs:
        base_row = stats[stats["config"] == "arms"].iloc[0]
        dp_row = stats[stats["config"] == "duration_pred"].iloc[0]
        base_mean = float(base_row["mean"])
        dp_mean = float(dp_row["mean"])
        if base_mean > 0:
            delta_pct = (dp_mean - base_mean) / base_mean * 100.0
            annot_color = "green" if delta_pct < 0 else "red"
            sign = "-" if delta_pct < 0 else "+"
            dp_idx = configs.index("duration_pred")
            dp_std = float(dp_row["std"]) if not np.isnan(dp_row["std"]) else 0.0
            y_anchor = dp_mean + dp_std
            ax.annotate(
                f"{sign}{abs(delta_pct):.1f}%",
                xy=(dp_idx, y_anchor),
                xytext=(0, 10),
                textcoords="offset points",
                ha="center",
                fontsize=12,
                fontweight="bold",
                color=annot_color,
            )
            ax.annotate(
                f"N={int(dp_row['N'])} iterations",
                xy=(dp_idx, y_anchor),
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
    """Line plot: mean average time vs fast memory size, one line per config."""
    stats = (
        df.groupby(["fast_mem_gb", "config"])["avg_time_seconds"]
        .agg(["mean", "std", "count"])
        .rename(columns={"count": "N"})
        .reset_index()
    )
    stats["std"] = stats["std"].fillna(0.0)
    stats = stats.sort_values("fast_mem_gb")

    fig, ax = plt.subplots(figsize=(10, 6))

    for cfg in CONFIGS:
        sub = stats[stats["config"] == cfg]
        if sub.empty:
            continue
        ax.errorbar(
            sub["fast_mem_gb"],
            sub["mean"],
            yerr=sub["std"],
            label=LABELS.get(cfg, cfg),
            color=COLORS.get(cfg, sns.color_palette("muted")[2]),
            marker=MARKERS.get(cfg, "^"),
            markersize=7,
            linewidth=2,
            capsize=4,
            capthick=1.5,
        )

    ax.set_xlabel("Fast memory size (GB)")
    ax.set_ylabel("Mean average time (s)")
    ax.set_title("gapbs bc -- ARMS vs Duration-Pred across memory tier sizes")
    ax.legend(frameon=True)

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
        print("Detected multi-size sweep data.\n")

        for fast_mem, group in df.groupby("fast_mem"):
            print(f"--- {fast_mem} ---")
            stats = summarize(group)
            for _, row in stats.iterrows():
                std = 0.0 if pd.isna(row["std"]) else float(row["std"])
                print(
                    f"  {LABELS.get(row['config'], row['config']):15s} N={int(row['N']):4d}  "
                    f"mean={row['mean']:.5f}s  std={std:.5f}s"
                )
            plot_bar_chart(
                stats,
                results_dir,
                suffix=str(fast_mem),
                title_extra=f"Fast memory: {fast_mem}",
            )

        print("\n--- Scaling plot ---")
        plot_scaling(df, results_dir)
    else:
        stats = summarize(df)
        print("Per-config summary (from iteration_times.csv):")
        for _, row in stats.iterrows():
            std = 0.0 if pd.isna(row["std"]) else float(row["std"])
            print(
                f"  {LABELS.get(row['config'], row['config']):15s} N={int(row['N']):4d}  "
                f"mean={row['mean']:.5f}s  std={std:.5f}s"
            )
        plot_bar_chart(stats, results_dir)


if __name__ == "__main__":
    main()
