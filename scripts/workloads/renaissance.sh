#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# =============================================================================
# Renaissance JVM Benchmark Suite
# =============================================================================
# Runs one renaissance benchmark per invocation, selected by -w.  The JVM heap
# is sized via $RENAISSANCE_HEAP (Xms=Xmx, no resize noise) and the GC by
# $RENAISSANCE_GC.  Per-iteration durations are written to a CSV sidecar so
# FOM parsing doesn't depend on stdout scraping.
# =============================================================================

RENAISSANCE_DIR="$CUR_PATH/renaissance"
RENAISSANCE_SBT="$RENAISSANCE_DIR/tools/sbt/bin/sbt"

# Curated whitelist — memory-heavy data/ML benchmarks that are interesting
# for tiering.  -w outside this list fails fast (rather than dispatching a
# tiny scrabble run no one wants to measure).
RENAISSANCE_WHITELIST=(
    page-rank
    als
    movie-lens
    chi-square
    gauss-mix
    naive-bayes
    log-regression
    dec-tree
    scala-kmeans
    fj-kmeans
    db-shootout
)

_renaissance_find_jar() {
    # Newest renaissance-gpl-*.jar under target/ (in case multiple builds linger).
    ls -t "$RENAISSANCE_DIR"/target/renaissance-gpl-*.jar 2>/dev/null | head -n1
}

_renaissance_in_whitelist() {
    local needle="$1"
    local w
    for w in "${RENAISSANCE_WHITELIST[@]}"; do
        [[ "$w" == "$needle" ]] && return 0
    done
    return 1
}

config_renaissance() {
    # $1 = config file (unused), $2 = WORKLOAD (benchmark name)
    local workload="${2:-${WORKLOAD:-}}"

    RENAISSANCE_HEAP="${RENAISSANCE_HEAP:-16G}"
    RENAISSANCE_GC="${RENAISSANCE_GC:-G1}"
    RENAISSANCE_REPS="${RENAISSANCE_REPS:-20}"
    # Node 0 has 10 CPUs; match merci/npb-cpp/llama (8) to leave headroom.
    RENAISSANCE_THREADS="${RENAISSANCE_THREADS:-8}"

    if ! _renaissance_in_whitelist "$workload"; then
        echo "ERROR: '$workload' is not in the renaissance whitelist." >&2
        echo "Allowed -w values:" >&2
        printf '  %s\n' "${RENAISSANCE_WHITELIST[@]}" >&2
        return 1
    fi

    echo "renaissance config: workload=$workload heap=$RENAISSANCE_HEAP gc=$RENAISSANCE_GC reps=$RENAISSANCE_REPS threads=$RENAISSANCE_THREADS"
}

build_renaissance() {
    local jar
    jar="$(_renaissance_find_jar)"
    if [[ -n "$jar" && -f "$jar" ]]; then
        echo "renaissance JAR present: $jar (skipping sbt build)"
        return 0
    fi

    if [[ ! -x "$RENAISSANCE_SBT" ]]; then
        echo "ERROR: bundled sbt not found at $RENAISSANCE_SBT" >&2
        return 1
    fi

    echo "renaissance JAR missing, building via sbt renaissancePackage (5-10 min)..."
    (cd "$RENAISSANCE_DIR" && "$RENAISSANCE_SBT" renaissancePackage) || {
        echo "ERROR: sbt renaissancePackage failed" >&2
        return 1
    }

    jar="$(_renaissance_find_jar)"
    if [[ -z "$jar" || ! -f "$jar" ]]; then
        echo "ERROR: build completed but no JAR found under $RENAISSANCE_DIR/target/" >&2
        return 1
    fi
    echo "renaissance build OK: $jar"
}

run_renaissance() {
    local workload="$1"

    local jar
    jar="$(_renaissance_find_jar)"
    if [[ -z "$jar" || ! -f "$jar" ]]; then
        echo "ERROR: renaissance JAR not found — run build_renaissance first" >&2
        return 1
    fi

    generate_workload_filenames "$workload"

    # CSV sidecar: one row per repetition (benchmark, nanos, uptime_ns, ...).
    local csv_out="${STDOUT%_stdout.txt}_renaissance.csv"

    # Keep renaissance scratch out of the repo root (defaults to cwd).
    local scratch_base="${OUTPUT_DIR}/renaissance_scratch"
    mkdir -p "$scratch_base"

    # ActiveProcessorCount caps JVM-internal pools (GC, FJP common, Spark
    # local[*]); -D properties pin the two pools that ignore it.
    local jvm_args="-Xms${RENAISSANCE_HEAP} -Xmx${RENAISSANCE_HEAP} -XX:+Use${RENAISSANCE_GC}GC"
    jvm_args+=" -XX:ActiveProcessorCount=${RENAISSANCE_THREADS}"
    jvm_args+=" -Djava.util.concurrent.ForkJoinPool.common.parallelism=${RENAISSANCE_THREADS}"
    jvm_args+=" -Dscala.concurrent.context.numThreads=${RENAISSANCE_THREADS}"
    local r_args="--csv \"$csv_out\" --scratch-base \"$scratch_base\" -r ${RENAISSANCE_REPS} ${workload}"
    local full_args="${jvm_args} -jar \"${jar}\" ${r_args}"

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "/usr/bin/java" "$full_args"

    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_renaissance() {
    return
}

clean_renaissance() {
    stop_bwmon || true
    # Renaissance can leave a JVM behind if a benchmark hangs; tidy up.
    sudo killall java 2>/dev/null || true
    return
}
