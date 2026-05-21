#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

config_faiss(){
    local _config_file="$1"
    local _workload="$2"

    num_threads=8

    demo_binary=""
    dataset_check_file=""

    case "$_workload" in
        sift1M)
            demo_binary="demo_sift1M"
            dataset_check_file="sift1M/sift_base.fvecs"
            ;;
        *)
            echo "ERROR: unknown faiss workload '$_workload'" >&2
            echo "Valid workloads: sift1M" >&2
            exit 1
            ;;
    esac
}

build_faiss(){
    local _workload="$1"
    local faiss_dir="$CUR_PATH/faiss"

    if [[ -n "$dataset_check_file" && ! -f "$faiss_dir/$dataset_check_file" ]]; then
        echo "[WARN] $faiss_dir/$dataset_check_file missing; downloading SIFT1M dataset."
        (cd "$faiss_dir" && \
            wget -nc ftp://ftp.irisa.fr/local/texmex/corpus/sift.tar.gz && \
            mkdir -p sift1M && \
            tar -xf sift.tar.gz -C sift1M --strip-components=1)
    fi

    (cd "$faiss_dir" && cmake -B build . \
        -DFAISS_ENABLE_GPU=OFF \
        -DFAISS_OPT_LEVEL=avx512 \
        -DCMAKE_BUILD_TYPE=Release \
        -DFAISS_ENABLE_PYTHON=OFF \
        -DBUILD_TESTING=OFF)

    (cd "$faiss_dir" && make -C build -j$(nproc) faiss_avx512 "$demo_binary")
}

run_faiss(){
    local workload=$1

    generate_workload_filenames "$workload"

    local binary_path="$CUR_PATH/faiss/build/demos/$demo_binary"

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "" \
        "cd \"$CUR_PATH/faiss\"
export OMP_NUM_THREADS=\"$num_threads\""

    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

clean_faiss(){
    stop_bwmon
    return
}
