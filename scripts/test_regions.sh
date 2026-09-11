#!/usr/bin/env bash
# Hardware-free checks for every application-zoned workload: the shared
# buffer/option contract, MERCI, GAPBS PageRank, and NPB-CG. Needs g++, make,
# and python3 only; no dataset download, root, NUMA movement, or PEBS.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== shared zoning helpers"
g++ -std=c++11 -O2 -Wall -Wextra -pthread -I"$root/common" \
    "$root/common/regent_regions/tests/zones_test.cpp" -ldl -o "$tmp/zones_test"
"$tmp/zones_test"
echo "== MERCI"
make -C "$root/MERCI/4_performance_evaluation" test
echo "== GAPBS pr"
python3 "$root/gapbs/test/test_pr_regions.py"
echo "== NPB-CG"
python3 "$root/NPB-CPP/NPB-OMP/CG/tests/test_cg_regions.py"
