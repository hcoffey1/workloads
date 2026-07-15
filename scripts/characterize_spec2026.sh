#!/bin/bash
#==============================================================================
# characterize_spec2026.sh
#
# Runs each SPEC CPU2026 subset workload once (no instrumentation, NUMA node 0),
# with all outputs going to one shared directory, then writes a workload
# descriptor per workload under config/workload_descriptors/spec2026_<w>.conf.
#
# The descriptor records the measured peak RSS (kB) + wall clock in the same
# format as the existing spec_*.conf files, so the CPU2026 workloads can be fed
# into future experiments / characterization sizing exactly like CPU2017's.
#
# Peak RSS is read from `Maximum resident set size (kbytes)` in each run's
# _time.txt (written by /usr/bin/time -v). Multi-invocation workloads
# (omnetpp/gcc/zstd) produce one _time.txt per sub-run; the descriptor lists
# each and uses the MAX as peak_rss_kb (sub-runs run sequentially, so fast-tier
# sizing only needs to cover the largest).
#
# Usage:
#   scripts/characterize_spec2026.sh [-o OUTDIR] [-w "w1 w2 ..."] [--descriptors-only]
#
#   -o OUTDIR            shared output dir (default results/spec2026_characterization)
#   -w "list"           subset of workloads (default: all 7)
#   --descriptors-only   skip running; (re)generate descriptors from an existing OUTDIR
#==============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUTDIR="results/spec2026_characterization"
DESC_DIR="config/workload_descriptors"
WORKLOADS="lbm fotonik3d roms cactus omnetpp gcc zstd"
RUN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUTDIR="$2"; shift 2 ;;
        -w) WORKLOADS="$2"; shift 2 ;;
        --descriptors-only) RUN=0; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

DATE="$(date +%F)"
mkdir -p "$OUTDIR" "$DESC_DIR"

# --- helpers ----------------------------------------------------------------

# Parse an /usr/bin/time -v "Elapsed (wall clock) time" value (h:mm:ss(.ss) or
# m:ss(.ss)) into whole seconds.
wall_to_secs() {
    local t="$1" h=0 m=0 s=0
    t="${t%.*}"                      # drop fractional seconds
    IFS=':' read -ra p <<< "$t"
    case "${#p[@]}" in
        3) h=${p[0]}; m=${p[1]}; s=${p[2]} ;;
        2) m=${p[0]}; s=${p[1]} ;;
        1) s=${p[0]} ;;
    esac
    echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Format whole seconds as M:SS (or H:MM:SS past an hour), matching the existing
# descriptors' style.
fmt_secs() {
    local sec="$1"
    if (( sec >= 3600 )); then
        printf '%d:%02d:%02d' $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
    else
        printf '%d:%02d' $((sec/60)) $((sec%60))
    fi
}

# --- run --------------------------------------------------------------------

if [[ "$RUN" -eq 1 ]]; then
    echo "== running SPEC CPU2026 workloads -> $OUTDIR (no instrumentation) =="
    for w in $WORKLOADS; do
        echo "---- run.sh -b spec2026 -w $w ----"
        ./run.sh -b spec2026 -w "$w" -o "$OUTDIR"
    done
fi

# --- descriptors ------------------------------------------------------------

echo "== writing descriptors -> $DESC_DIR =="
for w in $WORKLOADS; do
    # Collect this workload's per-run time files. Sub-run label is the numeric
    # token right after the workload name (single-invocation runs have none).
    # sort -V so sub-runs order numerically (…_9 before …_10, not lexically).
    mapfile -t files < <(ls "$OUTDIR"/spec2026_"${w}"_*_time.txt 2>/dev/null | sort -V)
    if [[ "${#files[@]}" -eq 0 ]]; then
        echo "  [$w] no _time.txt found in $OUTDIR; skipping (did the run succeed?)" >&2
        continue
    fi

    # Gather (label, rss_kb, wall_secs, wall_str) per file.
    local_labels=(); rss_list=(); wsec_list=(); wstr_list=()
    max_rss=0; total_secs=0
    for f in "${files[@]}"; do
        rss=$(grep -a 'Maximum resident set size' "$f" | grep -oE '[0-9]+' | head -1)
        wstr=$(grep -a 'Elapsed (wall clock) time' "$f" | awk '{print $NF}')
        [[ -z "$rss" ]] && { echo "  [$w] no RSS in $(basename "$f"); skipping file" >&2; continue; }
        wsec=$(wall_to_secs "${wstr:-0}")
        label=$(basename "$f" | sed -nE "s/^spec2026_${w}_([0-9]+)_.*/\1/p")
        local_labels+=("$label"); rss_list+=("$rss"); wsec_list+=("$wsec"); wstr_list+=("$wstr")
        (( rss > max_rss )) && max_rss="$rss"
        total_secs=$(( total_secs + wsec ))
    done

    (( max_rss == 0 )) && { echo "  [$w] no parseable RSS; skipping descriptor" >&2; continue; }
    max_mb=$(( max_rss / 1024 ))
    n="${#rss_list[@]}"
    conf="$DESC_DIR/spec2026_${w}.conf"

    {
        echo "# Workload descriptor: spec2026/$w"
        echo "# Single source of truth for this workload's measured peak RSS"
        echo "# (consumed by run_characterization.sh USE_PEAK_RSS_RATIO sizing)."
        if (( n == 1 )); then
            echo "# Single-invocation.  Wall clock ~$(fmt_secs "${wsec_list[0]}") per run"
            echo "# (no instrumentation, NUMA node 0, $DATE)."
            echo "suite=spec2026"
            echo "workload=$w"
            printf 'peak_rss_kb=%s   #   ~%s MB  (%s)\n' "$max_rss" "$max_mb" "$DATE"
        else
            echo "#"
            echo "# Multi-invocation: refrate runs $n independent sub-runs (${w}_1..${w}_$n),"
            echo "# each tracked as its own sub-run.  peak_rss_kb is the MAX across them;"
            echo "# they run sequentially, so fast-tier sizing only needs to cover the"
            echo "# largest."
            echo "# Per-sub-run peak RSS / wall clock (no instrumentation, NUMA node 0, $DATE):"
            for i in "${!rss_list[@]}"; do
                printf '#   %s: %s kB   %s\n' "${local_labels[$i]:-$((i+1))}" "${rss_list[$i]}" "$(fmt_secs "${wsec_list[$i]}")"
            done
            printf '#   => ~%s total wall for all %s sub-runs\n' "$(fmt_secs "$total_secs")" "$n"
            echo "suite=spec2026"
            echo "workload=$w"
            printf 'peak_rss_kb=%s   #   ~%s MB  (max of %s sub-runs, %s)\n' "$max_rss" "$max_mb" "$n" "$DATE"
        fi
    } > "$conf"
    echo "  [$w] -> $conf  (peak_rss_kb=$max_rss, ${n} invocation(s))"
done

echo "== done =="
