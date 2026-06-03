https://github.com/facebookresearch/faiss/tree/main
https://github.com/facebookresearch/faiss/blob/main/INSTALL.md

# Building

Basic requirements are a C++20 compiler and BLAS (recommends Intel MKL).
- https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html
- `sudo apt-get install intel-mkl -y`

~Also need SWIG for python binding.~~
- Simplified Wrapper and Interface Generator
- Disabled python for the build

```
cmake -B build . -DFAISS_ENABLE_GPU=OFF -DFAISS_OPT_LEVEL=avx2 -DCMAKE_BUILD_TYPE=Release -DFAISS_ENABLE_PYTHON=OFF -DBUILD_TESTIN
G=OFF
```
- Had to disable GPU, python, and build testing as they caused errors.
- Had to modify cmakelists to change cmake version to an older version as Ubuntu wasn't on latest.

## Make
```
make -C build -j faiss
```

With avx512 (preferred for best performance)
```
make -C build -j faiss_avx512
```

# Benchmark
https://github.com/facebookresearch/faiss/tree/main/demos
https://github.com/facebookresearch/faiss/blob/main/demos/demo_sift1M.cpp
Get data set
```
wget ftp://ftp.irisa.fr/local/texmex/corpus/sift.tar.gz
mkdir -p sift1M && tar -xf sift.tar.gz -C sift1M --strip-components=1
```
- strip components fixes the extraction path so we don't have nested directories.

```
# Build demo
make -C build demo_sift1M
# Run demo
./build/demos/demo_sift1M
```

