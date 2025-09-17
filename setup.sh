#!/bin/bash

git submodule init
git submodule update

sudo apt update
sudo apt install libnuma-dev libpmem-dev libaio-dev libssl-dev mpich -y

conda tos accept
conda create -n dataVis pandas matplotlib seaborn -y

# PEBS
cd scripts/PEBS_page_tracking/
git apply ../../patches/pebs.patch
make -j20
cd ../..

# flexkvs
cd flexkvs
git apply ../patches/flexkvs.patch
make -j20
cd ..

# GAPBS
cd gapbs
git apply ../patches/gapbs.patch
make bench-graphs -j2
make -j20
cd ..

# graph_500
cd graph500
#git apply ../patches/graph500.patch
git checkout master
#cd src
make -j20
cd ..

# liblinear
cd liblinear-2.47
wget https://www.csie.ntu.edu.tw/~cjlin/libsvmtools/datasets/binary/kdd12.xz
unxz kdd12.xz
rm kdd12.xz
make -j20
cd ..

# MERCI
cd MERCI
git apply ../patches/merci.patch
mkdir -p data/4_filtered/amazon_All
cd data/4_filtered/amazon_All
wget https://pages.cs.wisc.edu/~apoduval/MERCI/data/4_filtered/amazon_All/amazon_All_test_filtered.txt
wget https://pages.cs.wisc.edu/~apoduval/MERCI/data/4_filtered/amazon_All/amazon_All_train_filtered.txt
cd ../../..
mkdir -p data/5_patoh/amazon_All/partition_2748/
cd data/5_patoh/amazon_All/partition_2748/
wget https://pages.cs.wisc.edu/~apoduval/MERCI/data/5_patoh/amazon_All/partition_2748/amazon_All_train_filtered.txt.part.2748
cd ../../../..
# now in merci
cd 4_performance_evaluation/
mkdir bin
make -j20
cd ../..
# now in workloads

# silo
cd silo/silo
git apply ../../patches/silo.patch
make dbtest -j20
cd ../..

# XSBench
cd XSBench/openmp-threading
make -j20
cd ../..
