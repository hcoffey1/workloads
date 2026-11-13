#!/usr/bin/env python3
"""Heatmap + access-concentration plot for zipf_bench PEBS samples.

Reads the files zipf_bench writes with --perf-out PREFIX:
  PREFIX_meta.json, PREFIX_samples.bin, PREFIX_lost.csv, [PREFIX_perm.bin]

Writes PREFIX_zipf.png:
  left   one heatmap per event: x = time since run start, y = buffer VA
         (offset from the buffer base), colour = PEBS samples per cell
         (plasma + SymLogNorm, as in tiering_solutions/scripts/plot_regent_vis.py).
         Lost-sample records are marked as ticks under the time axis.
  right  cumulative concentration (style of
         tiering_solutions/scripts/page_access/plot_page_access_cdf.py):
         x = % of pages ranked hottest-first, y = cumulative % of samples, plus
         the analytic Zipf curve. Every page of the buffer is in the
         denominator, including pages that were never sampled. Two rankings
         per event:
           solid   pages ordered by their true Zipf rank (from PREFIX_perm.bin,
                   or the identity for --no-shuffle runs). Unbiased.
           thin    pages ordered by their own sample counts (what a tiering
                   system that only sees samples would infer).

With --by-rank (needs PREFIX_perm.bin, i.e. a shuffled run) the heatmap y-axis
is the page's Zipf rank instead of its VA, so the hot set is a band at the
bottom rather than scattered noise.

Note: with sparse sampling (samples per page << 1) the count-ranked curve sits
far above the true one (it reaches 100% once every sampled page is counted),
because ranking by noisy counts overfits; the rank-ordered curve does not.

--granularity BYTES (e.g. 2097152) aggregates samples into larger units (2 MiB
huge pages) for the heatmap y-axis and the concentration curve. A unit's true
hotness is the summed Zipf weight of its base pages; that sets its rank and the
analytic curve.

Usage: plot_zipf_bench.py PREFIX [--by-rank] [--granularity BYTES] [--time-bins N]
                          [--va-bins N] [--out PNG]
"""

import argparse
import csv
import json
import pathlib

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.colors import SymLogNorm  # noqa: E402

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
EVENT_COLOR = {"l3_miss": "#eb6834"}
EVENT_LABEL = {"l3_miss": "sampled L3-miss loads"}
THEORY_COLOR = INK_2

RECORD = np.dtype([("time_ns", "<u8"), ("addr", "<u8"), ("thread", "<u2"),
                   ("event", "u1"), ("pad", "V5")])


def load(prefix):
    meta = json.loads(pathlib.Path(prefix + "_meta.json").read_text())
    rec = np.fromfile(prefix + "_samples.bin", dtype=RECORD)
    lost = []
    lost_path = pathlib.Path(prefix + "_lost.csv")
    if lost_path.exists():
        with lost_path.open() as fh:
            lost = [r for r in csv.DictReader(fh) if r["kind"].startswith("lost")]
    perm = None
    perm_path = pathlib.Path(prefix + "_perm.bin")
    if perm_path.exists():
        perm = np.fromfile(perm_path, dtype="<u4")
    return meta, rec, lost, perm


def throughput(prefix, meta):
    """Million accesses/s from the meta file, or the run's stdout for older runs."""
    if "maccesses_per_s" in meta:
        return meta["maccesses_per_s"]
    import re
    stdout = pathlib.Path(prefix[: -len("_perf")] + "_stdout.txt") if prefix.endswith("_perf") else None
    if stdout and stdout.exists():
        m = re.search(r"maccesses_per_s=([0-9.]+)", stdout.read_text())
        if m:
            return float(m.group(1))
    return None


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(AXIS)
    ax.tick_params(colors=MUTED, labelsize=8)


def concentration(counts):
    """(x %, y %) hottest-first cumulative curve with a (0, 0) origin."""
    s = np.sort(counts)[::-1].astype(np.float64)
    n = len(s)
    x = np.arange(n + 1) / n * 100.0
    total = s.sum()
    y = np.concatenate([[0.0], np.cumsum(s) / total * 100.0]) if total else None
    return x, y


def analytic_curve(w, points=4000):
    """Hottest-first cumulative curve of true unit weights w."""
    w = np.sort(w)[::-1]
    n = len(w)
    c = np.concatenate([[0.0], np.cumsum(w) / w.sum() * 100.0])
    idx = np.unique(np.geomspace(1, n, points).astype(np.int64))
    idx = np.concatenate([[0], idx])
    return idx / n * 100.0, c[idx]


def pages_for(x, y, pct):
    i = int(np.searchsorted(y, pct - 1e-9))
    return x[min(i, len(x) - 1)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefix", help="the --perf-out PREFIX given to zipf_bench")
    ap.add_argument("--by-rank", action="store_true",
                    help="heatmap y = Zipf rank (needs PREFIX_perm.bin)")
    ap.add_argument("--time-bins", type=int, default=0,
                    help="heatmap columns (default: 2 per second of runtime)")
    ap.add_argument("--va-bins", type=int, default=512, help="heatmap rows")
    ap.add_argument("--granularity", type=int, default=0,
                    help="analysis unit in bytes, multiple of the page size (default: page size)")
    ap.add_argument("--out", help="output PNG (default: PREFIX_zipf.png)")
    args = ap.parse_args()

    meta, rec, lost, perm = load(args.prefix)
    base, length = meta["buf_base"], meta["buf_len"]
    page_size, n_pages = meta["page_size"], meta["pages"]
    t0, t1 = meta["t_start_ns"], meta["t_end_ns"]
    if not t0 and len(rec):  # no TSC conversion available: fall back to samples
        t0, t1 = int(rec["time_ns"].min()), int(rec["time_ns"].max())
    duration = max((t1 - t0) / 1e9, 1e-9)

    inbuf = (rec["addr"] >= base) & (rec["addr"] < base + length)
    rec = rec[inbuf]
    gran = args.granularity or page_size
    if gran % page_size:
        raise SystemExit("--granularity must be a multiple of the page size (%d)" % page_size)
    per_unit = gran // page_size
    n_units = n_pages // per_unit
    unit_name = "%s page" % ("%d MiB" % (gran >> 20) if gran >= 1 << 20 else "%d KiB" % (gran >> 10))
    page = ((rec["addr"] - base) // page_size).astype(np.int64)
    keep = page < n_units * per_unit  # drop a partial trailing unit
    rec, page = rec[keep], page[keep]
    unit = page // per_unit
    t = (rec["time_ns"].astype(np.int64) - t0) / 1e9
    if len(t):  # the meta window can end after the last sample (join/teardown)
        duration = min(duration, float(t.max()) + 1e-6)

    # True per-page rank (0 = hottest) -> per-unit weight -> per-unit rank.
    page_rank = None
    if perm is not None:
        page_rank = np.empty(n_pages, dtype=np.int64)
        page_rank[perm.astype(np.int64)] = np.arange(n_pages)
    elif meta["layout"] == "contiguous":
        page_rank = np.arange(n_pages, dtype=np.int64)
    unit_w = rank_of = None
    if page_rank is not None:
        w = (page_rank[: n_units * per_unit] + 1.0) ** -meta["theta"]
        unit_w = w.reshape(n_units, per_unit).sum(axis=1)
        rank_of = np.empty(n_units, dtype=np.int64)
        rank_of[np.argsort(-unit_w, kind="stable")] = np.arange(n_units)
    if args.by_rank:
        if rank_of is None:
            raise SystemExit("--by-rank needs PREFIX_perm.bin")
        ypos = rank_of[unit]
        ylabel = "true rank of %s (hottest at bottom)" % unit_name
    else:
        ypos = unit
        ylabel = "virtual address (GiB from buffer base)"

    events = meta["events"]
    time_bins = args.time_bins or max(1, int(round(duration * 2)))
    t_edges = np.linspace(0, duration, time_bins + 1)
    y_edges = np.linspace(0, n_units, min(args.va_bins, n_units) + 1)

    fig = plt.figure(figsize=(18, max(5.5, 3.4 * len(events) + 0.6)), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    gs = fig.add_gridspec(len(events), 3, width_ratios=(1.9, 1, 0.75), wspace=0.3, hspace=0.35,
                          left=0.05, right=0.98, top=0.86, bottom=0.2)

    lost_t = {}
    for r in lost:
        lost_t.setdefault(r["event"], []).append((int(r["time_ns"]) - t0) / 1e9)

    for row, ev in enumerate(events):
        name = ev["name"]
        sel = rec["event"] == ev["index"]
        ax = fig.add_subplot(gs[row, 0])
        style_axes(ax)
        grid, _, _ = np.histogram2d(t[sel], ypos[sel], bins=(t_edges, y_edges))
        vmax = max(grid.max(), 1.0)
        pcm = ax.pcolormesh(t_edges, y_edges, grid.T, cmap="plasma",
                            norm=SymLogNorm(linthresh=1.0, vmin=0, vmax=vmax),
                            rasterized=True, shading="flat")
        cb = fig.colorbar(pcm, ax=ax, pad=0.01, fraction=0.035)
        cb.set_label("PEBS samples / cell", color=INK_2, fontsize=8)
        cb.ax.tick_params(colors=MUTED, labelsize=7)
        if args.by_rank:
            ax.set_yticks(np.linspace(0, n_units, 6))
            ax.set_yticklabels(["%d%%" % p for p in range(0, 101, 20)])
        else:
            gib = length / 2**30
            step = max(1, int(round(gib / 8)))
            ticks = np.arange(0, gib + 1e-9, step)
            ax.set_yticks(ticks * 2**30 / gran)
            ax.set_yticklabels(["%g" % v for v in ticks])
        ax.set_xlim(0, duration)
        ax.set_ylim(0, n_units)
        ax.set_ylabel(ylabel, color=INK_2, fontsize=8)
        if row == len(events) - 1:
            ax.set_xlabel("time since run start (s)", color=INK_2, fontsize=9)
        lt = lost_t.get(name, [])
        lost_total = ev.get("lost", 0)
        if lt:
            ax.plot(lt, np.full(len(lt), -0.012 * n_units), "|", color="#d03b3b",
                    markersize=5, clip_on=False)
        ax.set_title("%s, %s granularity" % (name, unit_name),
                     color=INK, fontsize=10, loc="left", fontweight="bold")
        ax.text(1.0, 1.02, "%s period %d: %s samples in buffer, %s lost%s, %.1f%% unaccounted" % (
            ev["config"], ev.get("period", meta["perf_period"]),
            "{:,}".format(int(sel.sum())), "{:,}".format(lost_total),
            " (red ticks)" if lt else "", 100 * ev.get("unaccounted_frac", 0.0)),
            transform=ax.transAxes, ha="right", color=MUTED, fontsize=8)

    # Concentration plot spans the right column.
    ax = fig.add_subplot(gs[:, 1])
    style_axes(ax)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.set_xticks(range(0, 101, 20))
    ax.set_yticks(range(0, 101, 20))
    ax.grid(True, color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.plot([0, 100], [0, 100], color=MUTED, linewidth=1, linestyle=(0, (4, 3)))
    ax.text(62, 52, "uniform", color=MUTED, fontsize=8)

    hot_pct = 100.0 * meta["hot_pages"] / n_pages
    if unit_w is None:  # no layout info: base-page analytic curve
        unit_w = np.arange(1, n_units + 1, dtype=np.float64) ** -meta["theta"]
    zx, zy = analytic_curve(unit_w)
    ax.plot(zx, zy, color=THEORY_COLOR, linewidth=1.2, linestyle=(0, (1, 1.5)),
            label="Zipf θ=%.3f, true access share" % meta["theta"])
    zhot = np.interp(hot_pct, zx, zy)
    ax.plot([hot_pct], [zhot], marker="D", markersize=6,
            color=INK, markeredgecolor=SURFACE, markeredgewidth=1.5, zorder=5)
    lines = ["true accesses: %.1f%% in hottest %.0f%% of %ss" % (zhot, hot_pct, unit_name)]

    for ev in events:
        name = ev["name"]
        counts = np.bincount(unit[rec["event"] == ev["index"]], minlength=n_units)
        if not counts.sum():
            continue
        color = EVENT_COLOR.get(name, INK)
        x, y = concentration(counts)
        ax.plot(x, y, color=color, linewidth=0.9, alpha=0.6, solid_capstyle="round",
                label="%s, by sample count" % EVENT_LABEL.get(name, name))
        if rank_of is not None:
            by_rank = np.zeros(n_units)
            by_rank[rank_of] = counts  # position = true rank
            x = np.arange(n_units + 1) / n_units * 100.0
            y = np.concatenate([[0.0], np.cumsum(by_rank) / by_rank.sum() * 100.0])
            ax.plot(x, y, color=color, linewidth=2, solid_capstyle="round",
                    label="%s, by true rank" % EVENT_LABEL.get(name, name))
        hy = np.interp(hot_pct, x, y)
        ax.plot([hot_pct], [hy], marker="o", markersize=5, color=color,
                markeredgecolor=SURFACE, markeredgewidth=1.5, zorder=4)
        lines.append("%s%s: %.1f%% in hottest %.0f%%; 80%% in %.1f%% of %ss; %.1f samples/%s, %.1f%% of %ss sampled" % (
            name, " (by true rank)" if rank_of is not None else " (by sample count)",
            hy, hot_pct, pages_for(x, y, 80), unit_name, counts.sum() / n_units, unit_name,
            100 * (counts > 0).mean(), unit_name))
    ax.axvline(hot_pct, color=AXIS, linewidth=0.8, zorder=1)
    ax.set_xlabel("%% of %ss (hottest first)" % unit_name, color=INK_2, fontsize=9)
    ax.set_ylabel("cumulative % of samples", color=INK_2, fontsize=9)
    ax.set_title("Access concentration (%ss)" % unit_name, color=INK, fontsize=10, loc="left", fontweight="bold")
    ax.legend(loc="lower right", fontsize=7, frameon=False, labelcolor=INK_2)
    ax.text(1.0, -0.2, "\n".join(lines), transform=ax.transAxes, color=INK_2, fontsize=7,
            va="top", ha="right")

    # Pie: units that received >= 1 sample vs none, per event (first event shown).
    ev = events[0]
    counts = np.bincount(unit[rec["event"] == ev["index"]], minlength=n_units)
    hit = int((counts > 0).sum())
    pax = fig.add_subplot(gs[:, 2])
    pax.set_facecolor(SURFACE)
    vals = [hit, n_units - hit]
    labels = ["\u2265 1 sample", "0 samples"]
    colors = [EVENT_COLOR.get(ev["name"], INK), GRID]
    wedges, _ = pax.pie(vals, colors=colors, startangle=90, counterclock=False,
                        wedgeprops={"edgecolor": SURFACE, "linewidth": 1.5})
    pax.set_aspect("equal")
    pax.legend(wedges, ["%s: %s (%.1f%%)" % (lbl, "{:,}".format(v), 100 * v / n_units)
                        for lbl, v in zip(labels, vals)],
               loc="upper center", bbox_to_anchor=(0.5, -0.02), fontsize=8, frameon=False,
               labelcolor=INK_2, title="of %s %ss in the buffer" % ("{:,}".format(n_units), unit_name),
               title_fontsize=8)
    pax.set_title("%ss with an %s sample" % (unit_name, ev["name"].replace("_", "-")),
                  color=INK, fontsize=10, fontweight="bold")


    tput = throughput(args.prefix, meta)
    fig.suptitle("zipf_bench: %.0f GiB, %s, %s layout, %s, %d threads, target %.0f%% of accesses to %.0f%% of 4 KiB pages%s" % (
        length / 2**30, "THP-backed" if meta.get("thp") else "base-page-backed", meta["layout"], meta["mode"], meta["threads"],
        100 * meta["hot_access"], 100 * meta["hot_frac"],
        ", %.1fM accesses/s" % tput if tput is not None else ""),
        color=INK, fontsize=11, x=0.06, ha="left", fontweight="bold")

    out = args.out or args.prefix + "_zipf.png"
    fig.savefig(out, facecolor=SURFACE)
    plt.close(fig)
    print("Wrote", out)
    for line in lines:
        print(" ", line)


if __name__ == "__main__":
    main()
