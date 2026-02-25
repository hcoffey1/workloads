#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# =============================================================================
# llama.cpp Workload Script
# =============================================================================
# Runs llama-bench (or llama-cli / llama-perplexity) for LLM inference
# benchmarking.  The workload parameter selects the binary:
#   llama-bench      – throughput benchmark  (default)
#   llama-cli        – interactive / batch inference
#   llama-perplexity – perplexity evaluation
# =============================================================================

config_llama_cpp() {
    # ---- Model ----
    # Default model: TinyLlama 1.1B Q4_K_M (~670MB) – good for quick testing.
    # Override LLAMA_MODEL / LLAMA_MODEL_URL for larger models, e.g.:
    #   LLAMA_MODEL_URL="https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf"
    #   LLAMA_MODEL="$CUR_PATH/llama.cpp/models/llama-2-7b.Q4_K_M.gguf"
    LLAMA_MODEL_URL="${LLAMA_MODEL_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
    LLAMA_MODEL="${LLAMA_MODEL:-$CUR_PATH/llama.cpp/models/tinyllama-1.1b-q4km.gguf}"

    # ---- General ----
    LLAMA_THREADS="${LLAMA_THREADS:-8}"
    LLAMA_REPETITIONS="${LLAMA_REPETITIONS:-5}"
    LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-0}"   # 0 = CPU-only
    LLAMA_MMAP="${LLAMA_MMAP:-0}"                   # 0 = disable mmap (force read into RAM)

    # ---- llama-bench specific ----
    LLAMA_N_PROMPT="${LLAMA_N_PROMPT:-512}"          # prompt (prefill) tokens
    LLAMA_N_GEN="${LLAMA_N_GEN:-128}"                # generation tokens
    LLAMA_BATCH_SIZE="${LLAMA_BATCH_SIZE:-2048}"
    LLAMA_UBATCH_SIZE="${LLAMA_UBATCH_SIZE:-512}"
    LLAMA_OUTPUT_FMT="${LLAMA_OUTPUT_FMT:-md}"       # csv|json|jsonl|md|sql

    # ---- llama-cli specific (used when workload=llama-cli) ----
    LLAMA_PROMPT="${LLAMA_PROMPT:-"Building a website can be done in 10 simple steps:"}"
    LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-2048}"

    # ---- llama-perplexity specific ----
    LLAMA_PPL_DATASET="${LLAMA_PPL_DATASET:-}"       # path to dataset txt
}

build_llama_cpp() {
    local src_dir="$CUR_PATH/llama.cpp"
    local build_dir="$src_dir/build"

    # ---- Download model if it doesn't exist ----
    if [[ ! -f "$LLAMA_MODEL" ]]; then
        echo "Model not found at $LLAMA_MODEL – downloading..."
        local model_dir
        model_dir="$(dirname "$LLAMA_MODEL")"
        mkdir -p "$model_dir"
        if ! wget -q --show-progress -O "$LLAMA_MODEL" "$LLAMA_MODEL_URL"; then
            echo "ERROR: Failed to download model from $LLAMA_MODEL_URL"
            return 1
        fi
        echo "Model downloaded: $LLAMA_MODEL ($(du -h "$LLAMA_MODEL" | cut -f1))"
    else
        echo "Model already present: $LLAMA_MODEL ($(du -h "$LLAMA_MODEL" | cut -f1))"
    fi

    # ---- Build llama.cpp ----
    echo "Building llama.cpp ..."
    mkdir -p "$build_dir"
    (cd "$build_dir" && \
     cmake .. -DCMAKE_BUILD_TYPE=Release \
              -DGGML_NATIVE=ON \
              -DLLAMA_BUILD_TESTS=OFF \
              -DLLAMA_BUILD_EXAMPLES=ON && \
     cmake --build . --config Release -j "$(nproc)")

    if [[ ! -x "$build_dir/bin/llama-bench" ]]; then
        echo "ERROR: Build failed – llama-bench binary not found"
        return 1
    fi
    echo "Build successful: $build_dir/bin/"
}

run_llama_cpp() {
    local workload="${1:-llama-bench}"
    local bin_dir="$CUR_PATH/llama.cpp/build/bin"

    # Map generic workload name to the default benchmark binary
    if [[ "$workload" == "llama_cpp" ]]; then
        workload="llama-bench"
    fi

    local bin="$bin_dir/$workload"

    if [[ ! -x "$bin" ]]; then
        echo "ERROR: Binary not found at $bin"
        return 1
    fi

    # ---- Build argument list depending on selected binary ----
    local args=""
    case "$workload" in
        llama-bench)
            args="$args -m $LLAMA_MODEL"
            args="$args -t $LLAMA_THREADS"
            args="$args -r $LLAMA_REPETITIONS"
            args="$args -p $LLAMA_N_PROMPT"
            args="$args -n $LLAMA_N_GEN"
            args="$args -b $LLAMA_BATCH_SIZE"
            args="$args -ub $LLAMA_UBATCH_SIZE"
            args="$args -ngl $LLAMA_N_GPU_LAYERS"
            args="$args -mmp $LLAMA_MMAP"
            args="$args -o $LLAMA_OUTPUT_FMT"
            args="$args --progress"
            ;;
        llama-cli)
            args="$args -m $LLAMA_MODEL"
            args="$args -t $LLAMA_THREADS"
            args="$args -ngl $LLAMA_N_GPU_LAYERS"
            args="$args -c $LLAMA_CTX_SIZE"
            args="$args -n $LLAMA_N_GEN"
            args="$args --mmap $LLAMA_MMAP"
            args="$args -p \"$LLAMA_PROMPT\""
            ;;
        llama-perplexity)
            args="$args -m $LLAMA_MODEL"
            args="$args -t $LLAMA_THREADS"
            args="$args -ngl $LLAMA_N_GPU_LAYERS"
            if [[ -n "$LLAMA_PPL_DATASET" ]]; then
                args="$args -f $LLAMA_PPL_DATASET"
            fi
            ;;
        *)
            echo "WARNING: Unknown workload '$workload', passing model and threads only"
            args="$args -m $LLAMA_MODEL -t $LLAMA_THREADS"
            ;;
    esac

    # ---- Extra env vars (REGENT, huge-pages, etc.) ----
    local extra_envs=""
    if [[ -n "${REGENT_REGIONS:-}" ]]; then
        extra_envs="export REGENT_REGIONS=\"$REGENT_REGIONS\""
    fi
    if [[ -n "${REGENT_ANNOTATION_FILE:-}" ]]; then
        if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
        local anno_file="${REGENT_ANNOTATION_FILE}"
        if [[ -n "${CURRENT_ITERATION:-}" ]]; then
            if [[ "$anno_file" == *.* ]]; then
                local ext="${anno_file##*.}"
                local base="${anno_file%.*}"
                anno_file="${base}_iter${CURRENT_ITERATION}.${ext}"
            else
                anno_file="${anno_file}_iter${CURRENT_ITERATION}"
            fi
        fi
        extra_envs+="export REGENT_ANNOTATION_FILE=\"$anno_file\""
    fi
    if [[ -n "${REGENT_NUM_REGIONS:-}" ]]; then
        if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
        extra_envs+="export REGENT_NUM_REGIONS=\"$REGENT_NUM_REGIONS\""
    fi

    # Disable huge-pages by default (same as micro_interference)
    if [[ -n "$extra_envs" ]]; then extra_envs+=$'\n'; fi
    extra_envs+="export USE_HUGETLB=0"

    # ---- Standard workload execution ----
    generate_workload_filenames "$workload"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$bin" "$args" "$extra_envs"
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

run_strace_llama_cpp() {
    return
}

clean_llama_cpp() {
    stop_bwmon || true
    return
}
