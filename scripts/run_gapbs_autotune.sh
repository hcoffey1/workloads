#!/bin/bash
#==============================================================
# Slide experiment
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 10 -x 20 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 12 -x 20 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 10 -x 80 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 12 -x 80 -y 100

./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 10 -x 20 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 10 -x 80 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 12 -x 20 -y 100
./run.sh -b gapbs -w sssp -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 12 -x 80 -y 100

./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 10 -x 20 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 12 -x 20 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 10 -x 80 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 400ms -a 8s -n 4 -m 12 -x 80 -y 100

./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 10 -x 20 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 10 -x 80 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 12 -x 20 -y 100
./run.sh -b gapbs -w pr -o results/results_gapbs_auto_exp1 -i damon -s 100ms -a 2s -n 4 -m 12 -x 80 -y 100

#==============================================================
#Given best x y, Finding best initial -s -a
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 200ms -a 4s -n 4 -m 10 -x 20 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 100ms -a 2s -n 4 -m 10 -x 20 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 50ms -a 1s -n 4 -m 10 -x 20 -y 100

#==============================================================
#Finding best -x -y
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10 -x 4 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10 -x 20 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10 -x 50 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10 -x 80 -y 100
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10 -x 100 -y 100

#==============================================================
#./run.sh -b gapbs -w bc -o results/results_gapbs_n_m        -i pebs
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 100ms -a 2s
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w bc -o results/results_gapbs_auto        -i damon -s 400ms -a 8s -n 4 -m 12

#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10 
#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12 
#
#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w pr -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w pr_spmv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w cc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w cc_sv -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w bfs -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w sssp -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 8
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 10
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 100ms -a 2s -n 4 -m 12
#
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 8
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 10
#./run.sh -b gapbs -w tc -o results/results_gapbs_n_m_auto        -i damon -s 400ms -a 8s -n 4 -m 12
#==============================================================
