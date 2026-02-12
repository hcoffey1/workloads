#!/bin/bash
#==============================================================
./run.sh -b liblinear -w liblinear -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b flexkvs -w flexkvs -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b merci -w merci -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b graph500 -w graph500 -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w bc -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w pr -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w pr_spmv -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w cc -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w cc_sv -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w bfs -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w sssp -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
./run.sh -b gapbs -w tc -o results_pebs/results_pebs_1k_1s_lite -i pebs -s 1000 --record-vma
