#!/bin/bash
#==============================================================
./run.sh -b liblinear -w liblinear -o results/results_baseline

./run.sh -b flexkvs -w flexkvs -o results/results_baseline

./run.sh -b merci -w merci -o results/results_baseline

./run.sh -b graph500 -w graph500 -o results/results_baseline

./run.sh -b gapbs -w bc -o results/results_baseline

./run.sh -b gapbs -w pr -o results/results_baseline

./run.sh -b gapbs -w pr_spmv -o results/results_baseline

./run.sh -b gapbs -w cc -o results/results_baseline

./run.sh -b gapbs -w cc_sv -o results/results_baseline

./run.sh -b gapbs -w bfs -o results/results_baseline

./run.sh -b gapbs -w sssp -o results/results_baseline

./run.sh -b gapbs -w tc -o results/results_baseline
