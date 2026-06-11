#!/bin/bash

git submodule init
git submodule update

sudo apt update
#intel-mkl needed for Faiss as its BLAS library.
sudo apt install libnuma-dev libpmem-dev libaio-dev libssl-dev mpich intel-mkl -y

# For renaissance Java benchmarks
sudo apt-get install openjdk-21-jdk -y

conda tos accept
conda create -n dataVis pandas matplotlib seaborn -y

pushd scripts/cipp-workspace/tools
make clean
make ARCH=haswell -j 20
popd

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
#make bench-graphs -j2
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
pushd third-party/lz4
make library
popd
git apply ../../patches/silo.patch
make dbtest -j20
cd ../..

# XSBench
cd XSBench/openmp-threading
make -j20
cd ../..

#
pushd ./NPB-CPP/libs/tbb-2020.1/
# Build tbb library and make env source file executable.
make -j 32
chmod +x ./build/linux_intel64_gcc_cc11.4.0_libc2.35_kernel5.1.0_release/tbbvars.sh
popd

pushd ./minimap2
git submodule update --init --recursive
popd

# For solo-ann
sudo apt update && sudo apt install -y python3.10-venv python3.10-dev

# ==============================================================================
# SPEC CPU2017 (built when the source tree is available; auto-skipped otherwise)
# ==============================================================================
# Copies a SPEC install locally, writes a clean (non-XRay) -O3 gcc config, then
# builds and stages refrate run dirs for the memory-intensive subset used by
# scripts/workloads/spec.sh.  Heavy (~9GB copy + compile).  Runs by default when
# the source tree is present; auto-skips otherwise.  Force-skip with BUILD_SPEC=0.
SPEC_SRC="${SPEC_SRC:-/proj/instrument-PG0/spec}"
SPEC_DEST="${SPEC_DEST:-$HOME/spec}"
if [[ "${BUILD_SPEC:-1}" == "0" ]]; then
    echo "[spec] BUILD_SPEC=0; skipping SPEC build."
elif [[ ! -d "$SPEC_SRC" ]]; then
    echo "[spec] SPEC source not found at $SPEC_SRC; skipping SPEC build."
    echo "[spec] To enable, set SPEC_SRC=/path/to/spec (a SPEC CPU2017 install) and re-run."
else (
    echo "[spec] installing build toolchain (gcc/g++/gfortran/rsync)"
    sudo apt install -y gcc g++ gfortran rsync
    # Single-invocation, memory-intensive subset that builds cleanly with system
    # gcc 11 (see docs/spec2017_integration.md). 510.parest_r is intentionally
    # excluded: its deal.II sources don't compile with gcc 11.
    SPEC_BENCHMARKS="${SPEC_BENCHMARKS:-505.mcf_r 519.lbm_r 520.omnetpp_r 523.xalancbmk_r 507.cactuBSSN_r 549.fotonik3d_r 554.roms_r}"

    echo "[spec] copying $SPEC_SRC -> $SPEC_DEST"
    mkdir -p "$SPEC_DEST"
    # Skip the source tarball, prior (XRay) build artifacts, and results; we rebuild clean.
    rsync -a \
        --exclude 'cpu2017.tar.xz' \
        --exclude 'result/' \
        --exclude '*.log' \
        --exclude 'benchspec/CPU/*/run/' \
        --exclude 'benchspec/CPU/*/build/' \
        --exclude 'benchspec/CPU/*/exe/' \
        "$SPEC_SRC/" "$SPEC_DEST/"

    echo "[spec] writing clean-gcc config (system gcc, -O3 -march=native, no XRay)"
    cp "$SPEC_DEST/config/Example-gcc-linux-x86.cfg" "$SPEC_DEST/config/clean-gcc.cfg"
    sed -i -E 's|(define[[:space:]]+gcc_dir[[:space:]]+).*|\1/usr|' "$SPEC_DEST/config/clean-gcc.cfg"
    sed -i 's|%define label mytest|%define label clean|' "$SPEC_DEST/config/clean-gcc.cfg"
    # gcc 11 defaults to gnu++17, whose 3-arg std::hypot overload breaks
    # omnetpp's Define_Function3(SPEC_HYPOT,2,...) registration at runtime.
    # Build it against pre-C++17.
    cat >> "$SPEC_DEST/config/clean-gcc.cfg" <<'CFG'

520.omnetpp_r:  #lang='CXX'
   CXXPORTABILITY = -std=gnu++14
CFG

    cd "$SPEC_DEST"
    source ./shrc
    echo "[spec] building: $SPEC_BENCHMARKS"
    runcpu --config=clean-gcc --action=build $SPEC_BENCHMARKS
    echo "[spec] staging refrate run dirs: $SPEC_BENCHMARKS"
    runcpu --config=clean-gcc --action=setup --size=ref $SPEC_BENCHMARKS
    echo "[spec] done. Run with: ./run.sh -b spec -w mcf -o results/spec_test"
) fi
