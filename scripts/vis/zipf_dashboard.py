#!/usr/bin/env python3
"""Static dashboard of zipf_bench PEBS figures, optionally served over HTTP.

Finds every zipf_bench run under the given directories (a run is a
*_perf_meta.json file), renders its VA and Zipf-rank figures with
plot_zipf_bench.py, and writes OUT/index.html with one card per run.
Re-run it to pick up new runs; figures already newer than their samples are
reused.

Usage:
  zipf_dashboard.py DIR [DIR ...] [--out results/zipf_dashboard] [--serve PORT] [--bind ADDR]

--serve serves only OUT (not the repo) until killed. Runs with whatever python
invokes it, which needs numpy + matplotlib (e.g. ~/miniconda3/envs/dataVis).
"""

import argparse
import datetime
import functools
import hashlib
import html
import http.server
import json
import pathlib
import subprocess
import sys

PLOT = pathlib.Path(__file__).resolve().parent / "plot_zipf_bench.py"
sys.path.insert(0, str(PLOT.parent))
from plot_zipf_bench import throughput  # noqa: E402
GRANULARITIES = (("4k", 0), ("2m", 2 << 20))  # 0 = the run's own page size

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>zipf_bench dashboard</title>
<style>
:root {{ --bg:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781; --line:#e1e0d9; --card:#fff; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#141413; --ink:#f4f3ee; --ink2:#c3c2b7;
  --muted:#898781; --line:#2e2d2a; --card:#1c1c1a; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:14px/1.45 system-ui,sans-serif; }}
main {{ max-width:1400px; margin:0 auto; padding:24px 16px 48px; }}
h1 {{ font-size:20px; margin:0 0 4px; }}
.sub {{ color:var(--muted); margin:0 0 24px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px; margin-bottom:24px; }}
.card h2 {{ font-size:15px; margin:0 0 2px; word-break:break-all; }}
.path {{ color:var(--muted); font-size:12px; word-break:break-all; margin-bottom:12px; }}
.stats {{ display:flex; flex-wrap:wrap; gap:8px 24px; margin-bottom:12px; }}
.stat b {{ display:block; font-size:16px; font-variant-numeric:tabular-nums; }}
.stat span {{ color:var(--muted); font-size:12px; }}
.warn b {{ color:#d03b3b; }}
.tabs {{ display:inline-block; margin:0 16px 6px 0; }}
.tabs button {{ font:inherit; background:none; border:1px solid var(--line); color:var(--ink2);
  padding:4px 12px; border-radius:6px; cursor:pointer; margin-right:6px; }}
.tabs button[aria-pressed=true] {{ background:var(--ink); color:var(--bg); border-color:var(--ink); }}
.fig {{ margin-top:10px; background:#fcfcfb; border-radius:6px; overflow:hidden; }}
.fig img {{ width:100%; height:auto; display:block; }}
a {{ color:inherit; }}
.files {{ font-size:12px; color:var(--muted); margin-top:8px; }}
.empty {{ color:var(--muted); }}
</style></head><body><main>
<h1>zipf_bench dashboard</h1>
<p class="sub">{n} run(s), generated {now}. Heatmap: time &times; buffer VA or Zipf rank, colour = PEBS L3-miss samples. Right: cumulative % of samples vs % of pages.</p>
{cards}
</main>
<script>
document.querySelectorAll('.card').forEach(function (card) {{
  var fig = card.querySelector('.fig'), img = fig.querySelector('img'), link = fig.querySelector('a');
  var figs = JSON.parse(fig.dataset.figs);
  function sel(axis) {{
    var b = card.querySelector('.tabs[data-axis=' + axis + '] button[aria-pressed=true]');
    return b ? b.dataset.val : '';
  }}
  card.querySelectorAll('.tabs').forEach(function (group) {{
    group.querySelectorAll('button').forEach(function (b) {{
      b.addEventListener('click', function () {{
        group.querySelectorAll('button').forEach(function (o) {{ o.setAttribute('aria-pressed', o === b); }});
        var src = figs[sel('gran') + '_' + sel('view')];
        if (src) {{ img.src = src; link.href = src; }}
      }});
    }});
  }});
}});
</script></body></html>
"""


def fmt(n):
    return "{:,}".format(int(n))


def render(prefix, out_png, by_rank, gran=0):
    samples = pathlib.Path(str(prefix) + "_samples.bin")
    if out_png.exists() and out_png.stat().st_mtime >= samples.stat().st_mtime:
        return True
    cmd = [sys.executable, "-I", str(PLOT), str(prefix), "--out", str(out_png)]
    if by_rank:
        cmd.append("--by-rank")
    if gran:
        cmd += ["--granularity", str(gran)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print("plot failed for %s:\n%s" % (prefix, r.stderr), file=sys.stderr)
    return r.returncode == 0


def card(meta_path, out):
    prefix = pathlib.Path(str(meta_path)[: -len("_meta.json")])
    meta = json.loads(meta_path.read_text())
    key = hashlib.sha1(str(prefix).encode()).hexdigest()[:10]
    have_rank = bool(meta.get("perm_file") or meta.get("layout") == "contiguous")
    # figures[(granularity, view)] = filename
    figures = {}
    for gname, gbytes in GRANULARITIES:
        for view in (("rank", "va") if have_rank else ("va",)):
            png = out / ("%s_%s_%s.png" % (key, gname, view))
            if render(prefix, png, view == "rank", gbytes):
                figures[(gname, view)] = png.name
    if not figures:
        return None

    ev = meta["events"][0]
    tput = throughput(str(prefix), meta)
    unacc = 100 * ev.get("unaccounted_frac", 0.0)
    stats = [
        ("%.0f GiB" % (meta["buf_len"] / 2**30), "buffer"),
        ("%.0f%% &rarr; %.0f%%" % (100 * meta["hot_access"], 100 * meta["hot_frac"]), "accesses &rarr; pages"),
        ("%.3f" % meta["theta"], "Zipf &theta;"),
        ("%.1f s" % meta.get("runtime_s", (meta["t_end_ns"] - meta["t_start_ns"]) / 1e9), "runtime"),
        ("%s" % ("%.1fM/s" % tput if tput is not None else "?"), "throughput (accesses)"),
        ("%d" % meta["threads"], "threads (%s)" % meta["layout"]),
        ("%s" % ("THP %.0f%%" % (100 * meta["anon_huge_bytes"] / meta["buf_len"])
                 if meta.get("thp") else "4 KiB"), "buffer backing"),
        (fmt(ev.get("period", meta["perf_period"])), "PEBS period"),
        (fmt(ev["samples"]), "samples in buffer"),
        (fmt(ev["lost"]), "lost"),
        ("%.1f%%" % unacc, "unaccounted"),
    ]
    stat_html = "".join(
        '<div class="stat%s"><b>%s</b><span>%s</span></div>' % (
            " warn" if (label == "lost" and ev["lost"]) or (label == "unaccounted" and unacc > 5) else "",
            v, label)
        for v, label in stats)
    views = [v for v in ("rank", "va") if any(k[1] == v for k in figures)]
    grans = [g for g, _ in GRANULARITIES if any(k[0] == g for k in figures)]
    first = figures[(grans[0], views[0])]
    view_label = {"rank": "by true rank", "va": "by virtual address"}
    gran_label = {"4k": "4 KiB pages", "2m": "2 MiB pages"}
    tabs = '<div class="tabs" data-axis="gran">%s</div><div class="tabs" data-axis="view">%s</div>' % (
        "".join('<button data-val="%s" aria-pressed="%s">%s</button>' % (g, str(i == 0).lower(), gran_label[g])
                for i, g in enumerate(grans)),
        "".join('<button data-val="%s" aria-pressed="%s">%s</button>' % (v, str(i == 0).lower(), view_label[v])
                for i, v in enumerate(views)))
    figmap = html.escape(json.dumps({"%s_%s" % k: v for k, v in figures.items()}))
    mtime = datetime.datetime.fromtimestamp(meta_path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
    return mtime, (
        '<section class="card"><h2>%s</h2><div class="path">%s &middot; %s</div>'
        '<div class="stats">%s</div>%s'
        '<div class="fig" data-figs="%s"><a href="%s"><img src="%s" alt="zipf_bench figure"></a></div></section>' % (
            html.escape(prefix.name), html.escape(str(prefix.parent)), mtime,
            stat_html, tabs, figmap, first, first))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", type=pathlib.Path)
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("results/zipf_dashboard"))
    ap.add_argument("--serve", type=int, metavar="PORT")
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    metas = sorted({m.resolve() for d in args.dirs for m in d.rglob("*_perf_meta.json")})
    cards = [c for c in (card(m, out) for m in metas) if c]
    cards.sort(key=lambda c: c[0], reverse=True)
    body = "\n".join(c[1] for c in cards) or '<p class="empty">No zipf_bench runs found.</p>'
    (out / "index.html").write_text(PAGE.format(
        n=len(cards), now=datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), cards=body))
    print("Wrote %s (%d runs)" % (out / "index.html", len(cards)))

    if args.serve:
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(out))
        srv = http.server.ThreadingHTTPServer((args.bind, args.serve), handler)
        print("Serving %s on http://%s:%d/" % (out, args.bind, args.serve), flush=True)
        srv.serve_forever()


if __name__ == "__main__":
    main()
