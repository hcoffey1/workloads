#!/bin/bash

./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i pebs
#================================================================
./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 1s  -n 4 -m 8
./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 200ms -a 1s -n 4 -m 8

./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 5s -n 4 -m 8
./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 200ms -a 1s -n 4 -m 8
./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 500ms -a 5s -n 4 -m 8

#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 50ms 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 50ms -n 4 -m 8
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 50ms -n 4 -m 16
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 50ms -n 8 -m 16
#
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 25ms -n 4 -m 8 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 25ms -n 4 -m 16 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 25ms -n 8 -m 16 
#
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 25ms -n 4 -m 8 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 25ms -n 4 -m 16 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 2ms -a 25ms -n 8 -m 16 
#
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 50ms -n 4 -m 8 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 50ms -n 4 -m 16 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 1ms -a 50ms -n 8 -m 16 
#
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 4ms -a 100ms -n 4 -m 8 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 4ms -a 100ms -n 4 -m 16 
#./run.sh -b masim -w masim -o results/results_masim_l_n_m_extend -i damon -s 4ms -a 100ms -n 8 -m 16 
#====================================================
