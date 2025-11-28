#!/bin/bash

#==============================================================
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w pr -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w cc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32

./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i pebs
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 8
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 16
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 100ms -a 2s -n 4 -m 32

./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 8
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 16
./run.sh -b gapbs -w tc -o results/results_gapbs_n_m        -i damon -s 400ms -a 8s -n 4 -m 32
#==============================================================
