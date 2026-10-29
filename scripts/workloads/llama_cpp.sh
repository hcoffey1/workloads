#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# =============================================================================
# llama.cpp Workload Script
# =============================================================================
# Runs llama.cpp binaries for LLM inference benchmarking.
# The workload parameter selects the binary:
#   llama-bench / llama_cpp  – throughput benchmark  (default)
#   llama-cli                – interactive / batch inference
#   llama-perplexity         – perplexity evaluation
#   llama-server / llama_server – multi-session serving benchmark
#       (llama-server starts the C++ server; a Python client drives load.
#        workload_pid = server PID, so PEBS instruments the right binary.)
#   qwen                     – single-user replay of WildChat prompts on
#       Qwen3-30B-A3B (MoE) via llama-server; per-request server timings land in
#       qwen_replay_iter<N>.jsonl. Data: ./setup.sh llama_models
#   mixtral                  – the same replay on Mixtral-8x7B-Instruct (8 experts,
#       top-2), Q4_K_M from worthdoing/Mixtral-8x7B-Instruct-v0.1-GGUF (older
#       GGUFs use split per-expert tensors this llama.cpp no longer loads).
#       Repacking is off by default so the weights keep their GGUF layout.
# =============================================================================

# ---- internal state for llama-server mode ----
_LLAMA_SERVER_BENCH_PID=""

config_llama_cpp() {
    # ---- qwen replay defaults (args: config_file, workload) ----
    if [[ "${2:-}" == "qwen" ]]; then
        LLAMA_MODEL="${LLAMA_MODEL:-$CUR_PATH/llama.cpp/models/Qwen3-30B-A3B-Q8_0.gguf}"
        LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"  # ~1.5K-token prompts + 8192-token thinking replies
    elif [[ "${2:-}" == "mixtral" ]]; then
        LLAMA_MODEL="${LLAMA_MODEL:-$CUR_PATH/llama.cpp/models/Mixtral-8x7B-Instruct-v0.1-Q4_K_M.gguf}"
        LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-8192}"
        # Q4_K is repacked into an interleaved buffer on AVX2; keep the file layout for expert mapping
        LLAMA_REPACK="${LLAMA_REPACK:-0}"
    fi
    LLAMA_REPACK="${LLAMA_REPACK:-1}"                       # 0 = pass --no-repack
    LLAMA_REPLAY_PROMPTS="${LLAMA_REPLAY_PROMPTS:-$CUR_PATH/llama.cpp/models/wildchat/prompts.jsonl}"
    LLAMA_REPLAY_N="${LLAMA_REPLAY_N:-20}"                   # first N prompts of the fixed pool
    LLAMA_THINKING="${LLAMA_THINKING:-0}"                   # 1 = Qwen3 thinking mode (-rea on)
    LLAMA_ROUTER_LOG="${LLAMA_ROUTER_LOG:-0}"               # 1 = log MoE router picks to <name>_router.bin
    # Per-request cap, high enough that most replies end on their own (finish_reason=stop)
    local max_tokens_default=2048; [[ "$LLAMA_THINKING" == 1 ]] && max_tokens_default=8192
    LLAMA_REPLAY_MAX_TOKENS="${LLAMA_REPLAY_MAX_TOKENS:-$max_tokens_default}"

    # ---- Model ----
    # Default model: TinyLlama 1.1B Q4_K_M (~670MB) – good for quick testing.
    # Override LLAMA_MODEL / LLAMA_MODEL_URL for larger models, e.g.:
    #   LLAMA_MODEL_URL="https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf"
    #   LLAMA_MODEL="$CUR_PATH/llama.cpp/models/llama-2-7b.Q4_K_M.gguf"
    # MoE model (fetch with `./setup.sh llama_models`):
    #   LLAMA_MODEL="$CUR_PATH/llama.cpp/models/Qwen3-30B-A3B-Q8_0.gguf"
    # The TinyLlama URL only defaults with the default path, so an overridden
    # LLAMA_MODEL is never auto-filled with the wrong weights.
    if [[ -z "${LLAMA_MODEL:-}" ]]; then
        LLAMA_MODEL_URL="${LLAMA_MODEL_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
    fi
    LLAMA_MODEL_URL="${LLAMA_MODEL_URL:-}"
    LLAMA_MODEL="${LLAMA_MODEL:-$CUR_PATH/llama.cpp/models/tinyllama-1.1b-q4km.gguf}"

    # ---- General ----
    LLAMA_THREADS="${LLAMA_THREADS:-8}"
    LLAMA_REPETITIONS="${LLAMA_REPETITIONS:-5}"
    LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-0}"   # 0 = CPU-only
    LLAMA_MMAP="${LLAMA_MMAP:-0}"                   # 0 = disable mmap (force read into RAM)
    LLAMA_LOAD_MODE=none; [[ "$LLAMA_MMAP" == 1 ]] && LLAMA_LOAD_MODE=mmap   # passed as -lm (replaced -mmp/--mmap)

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

    # ---- llama-server specific (used when workload=llama-server) ----
    LLAMA_SERVER_HOST="${LLAMA_SERVER_HOST:-127.0.0.1}"
    LLAMA_SERVER_PORT="${LLAMA_SERVER_PORT:-8080}"
    LLAMA_SERVER_PARALLEL="${LLAMA_SERVER_PARALLEL:-4}"       # concurrent serving slots
    LLAMA_SERVER_N_PREDICT="${LLAMA_SERVER_N_PREDICT:-128}"   # max tokens per request
    LLAMA_SERVER_CLIENTS="${LLAMA_SERVER_CLIENTS:-$LLAMA_SERVER_PARALLEL}"
    LLAMA_SERVER_ROUNDS="${LLAMA_SERVER_ROUNDS:-3}"
    LLAMA_SERVER_PROMPT_TOKENS="${LLAMA_SERVER_PROMPT_TOKENS:-128}"
    LLAMA_SERVER_GEN_TOKENS="${LLAMA_SERVER_GEN_TOKENS:-64}"
    LLAMA_SERVER_READY_TIMEOUT="${LLAMA_SERVER_READY_TIMEOUT:-600}"  # s; large models load slowly
    LLAMA_SERVER_STOP_TIMEOUT="${LLAMA_SERVER_STOP_TIMEOUT:-120}"    # s; grace before SIGKILL
}

build_llama_cpp() {
    local src_dir="$CUR_PATH/llama.cpp"
    local build_dir="$src_dir/build"

    # ---- Download model if it doesn't exist ----
    if [[ ! -f "$LLAMA_MODEL" && -z "$LLAMA_MODEL_URL" ]]; then
        echo "ERROR: Model not found at $LLAMA_MODEL and LLAMA_MODEL_URL is unset (for the MoE model run ./setup.sh llama_models)"
        return 1
    elif [[ ! -f "$LLAMA_MODEL" ]]; then
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

    # Normalize underscore to hyphen for binary lookup
    local workload_normalized="${workload//_/-}"

    # Dispatch llama-server (and the qwen replay built on it) to its own handler
    if [[ "$workload_normalized" == "llama-server" ]]; then
        _run_llama_server
        return $?
    elif [[ "$workload" == "qwen" || "$workload" == "mixtral" ]]; then
        _run_llama_server replay "$workload"
        return $?
    fi

    local bin="$bin_dir/$workload_normalized"

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
            args="$args -lm $LLAMA_LOAD_MODE"
            args="$args -o $LLAMA_OUTPUT_FMT"
            args="$args --progress"
            ;;
        llama-cli)
            args="$args -m $LLAMA_MODEL"
            args="$args -t $LLAMA_THREADS"
            args="$args -ngl $LLAMA_N_GPU_LAYERS"
            args="$args -c $LLAMA_CTX_SIZE"
            args="$args -n $LLAMA_N_GEN"
            args="$args -lm $LLAMA_LOAD_MODE"
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
    run_workload_standard

    start_bwmon
}

run_strace_llama_cpp() {
    return
}

# =============================================================================
# llama-server mode: internal handler
# =============================================================================
# Args: "replay" = single-user prompt replay (default = multi-session load); replay name (qwen|mixtral).
_run_llama_server() {
    local mode="${1:-load}" replay_name="${2:-qwen}"
    local server_bin="$CUR_PATH/llama.cpp/build/bin/llama-server"
    local bench_script="$CUR_PATH/scripts/workloads/vllm_bench_client.py"
    local parallel="$LLAMA_SERVER_PARALLEL" n_predict="$LLAMA_SERVER_N_PREDICT" name="llama_server"
    if [[ "$mode" == "replay" ]]; then
        bench_script="$CUR_PATH/scripts/workloads/llama_replay_client.py"
        parallel=1 n_predict="$LLAMA_REPLAY_MAX_TOKENS" name="$replay_name"
        if [[ ! -f "$LLAMA_REPLAY_PROMPTS" ]]; then
            echo "ERROR: replay prompts not found at $LLAMA_REPLAY_PROMPTS (run ./setup.sh llama_models)"
            return 1
        fi
    fi

    if [[ ! -x "$server_bin" ]]; then
        echo "ERROR: llama-server binary not found at $server_bin"
        return 1
    fi

    # ---- Build server command line ----
    local server_args=""
    server_args="$server_args -m $LLAMA_MODEL"
    server_args="$server_args -t $LLAMA_THREADS"
    server_args="$server_args -c $LLAMA_CTX_SIZE"
    server_args="$server_args -np $parallel"
    server_args="$server_args -n $n_predict"
    if [[ "$mode" == "replay" ]]; then
        local rea=off; [[ "$LLAMA_THINKING" == 1 ]] && rea=on
        server_args="$server_args -rea $rea"
    fi
    server_args="$server_args -ngl $LLAMA_N_GPU_LAYERS"
    server_args="$server_args --host $LLAMA_SERVER_HOST"
    server_args="$server_args --port $LLAMA_SERVER_PORT"
    server_args="$server_args -lm $LLAMA_LOAD_MODE"
    [[ "$LLAMA_REPACK" == 0 ]] && server_args="$server_args --no-repack"
    server_args="$server_args --metrics"

    # ---- Generate standard filenames ----
    generate_workload_filenames "$name"

    local server_stderr="${OUTPUT_DIR}/${name}_server_stderr.txt"

    # ---- Start llama-server via wrapper (LD_PRELOAD + PEBS track this PID) ----
    local server_env="export USE_HUGETLB=0"
    # Router log (llama-server patch): per layer and batch, the experts chosen for each token.
    [[ "$LLAMA_ROUTER_LOG" == 1 ]] && server_env="$server_env; export LLAMA_ROUTER_LOG=${OUTPUT_DIR}/${name}_router.bin"
    create_workload_wrapper "$WRAPPER" "$PIDFILE" \
        "$server_bin" "$server_args" "$server_env"

    echo "Starting llama-server (${parallel} parallel slots)..."

    set +e
    sudo numactl $(workload_numa_args) \
        /usr/bin/time -v -o "$TIMEFILE" \
        "$WRAPPER" \
        1> /dev/null 2> "$server_stderr" &

    # Wait for server PID
    local count=0
    while [ ! -s "$PIDFILE" ] && [ $count -lt 1000 ]; do
        sleep 0.01
        count=$((count + 1))
    done
    set -e

    if [ ! -s "$PIDFILE" ]; then
        echo "ERROR: Timeout waiting for server PID file"
        return 1
    fi

    # workload_pid = server PID (C++ binary with all model memory)
    # PEBS instruments THIS process, not the Python client.
    workload_pid=$(cat "$PIDFILE")
    echo "llama-server PID (workload_pid): $workload_pid"

    if [[ "${USE_CGROUP:-0}" == "1" ]]; then
        echo "Adding server PID $workload_pid to experiment cgroup"
        add_to_cgroup "$workload_pid" || true
    fi

    rm -f "$WRAPPER" "$PIDFILE"

    # ---- Wait for server health endpoint ----
    echo "Waiting for server to become ready..."
    local ready=0
    local attempt=0
    while [ $attempt -lt "$LLAMA_SERVER_READY_TIMEOUT" ]; do
        if curl -sf "http://${LLAMA_SERVER_HOST}:${LLAMA_SERVER_PORT}/health" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    if [[ $ready -ne 1 ]]; then
        echo "ERROR: llama-server did not become ready within ${LLAMA_SERVER_READY_TIMEOUT} seconds"
        echo "Server stderr:"
        tail -20 "$server_stderr"
        return 1
    fi
    echo "Server ready after ~${attempt}s."

    # ---- Launch benchmark client in background ----
    local bench_args=""
    bench_args="$bench_args --host $LLAMA_SERVER_HOST"
    bench_args="$bench_args --port $LLAMA_SERVER_PORT"
    local json_output bench_stdout="${OUTPUT_DIR}/${name}_bench_stdout.txt"
    local bench_stderr="${OUTPUT_DIR}/${name}_bench_stderr.txt"
    if [[ "$mode" == "replay" ]]; then
        json_output="${OUTPUT_DIR}/${name}_replay_iter${CURRENT_ITERATION:-0}.jsonl"
        bench_args="$bench_args --prompts $LLAMA_REPLAY_PROMPTS"
        bench_args="$bench_args --n $LLAMA_REPLAY_N"
        bench_args="$bench_args --max-tokens $LLAMA_REPLAY_MAX_TOKENS"
        bench_args="$bench_args --out $json_output"
        echo "Launching replay client ($LLAMA_REPLAY_N prompts, thinking=$LLAMA_THINKING)..."
    else
        json_output="${OUTPUT_DIR}/llama_server_bench_iter${CURRENT_ITERATION:-0}.json"
        bench_args="$bench_args --clients $LLAMA_SERVER_CLIENTS"
        bench_args="$bench_args --rounds $LLAMA_SERVER_ROUNDS"
        bench_args="$bench_args --prompt-tokens $LLAMA_SERVER_PROMPT_TOKENS"
        bench_args="$bench_args --gen-tokens $LLAMA_SERVER_GEN_TOKENS"
        echo "Launching benchmark client ($LLAMA_SERVER_CLIENTS concurrent, $LLAMA_SERVER_ROUNDS rounds)..."
    fi
    VLLM_BENCH_JSON_OUTPUT="$json_output" \
        python3 "$bench_script" $bench_args \
        1> "$bench_stdout" 2> "$bench_stderr" &
    _LLAMA_SERVER_BENCH_PID=$!
    echo "Benchmark client PID: $_LLAMA_SERVER_BENCH_PID"

    start_bwmon

    # ---- Wait for benchmark client to finish ----
    echo "Waiting for benchmark client to finish..."
    local client_rc=0
    wait $_LLAMA_SERVER_BENCH_PID 2>/dev/null || client_rc=$?
    _LLAMA_SERVER_BENCH_PID=""
    echo "Benchmark client finished (status $client_rc)."
    if (( client_rc != 0 )); then
        echo "ERROR: benchmark client failed (see $bench_stderr)" >&2
        WORKLOAD_RC=$client_rc   # run.sh exits with this; the server itself is killed on purpose
    fi

    if [[ -f "$bench_stdout" ]]; then
        echo "--- Benchmark Results ---"
        cat "$bench_stdout"
        echo "--- End Results ---"
    fi

    # Kill the server now that the benchmark is done
    echo "Stopping llama-server (PID $workload_pid)..."
    sudo kill "$workload_pid" 2>/dev/null || true
    # Let the server exit normally: the tiering lib finalizes its telemetry in an atexit hook.
    local waited=0
    while sudo kill -0 "$workload_pid" 2>/dev/null && (( waited < LLAMA_SERVER_STOP_TIMEOUT )); do
        sleep 1
        waited=$((waited + 1))
    done
    if sudo kill -0 "$workload_pid" 2>/dev/null; then
        echo "WARNING: llama-server still alive after ${LLAMA_SERVER_STOP_TIMEOUT}s; sending SIGKILL" >&2
        sudo kill -9 "$workload_pid" 2>/dev/null || true
    fi
}

clean_llama_cpp() {
    stop_bwmon || true

    # Kill benchmark client if still running (llama-server mode)
    if [[ -n "${_LLAMA_SERVER_BENCH_PID:-}" ]]; then
        kill "$_LLAMA_SERVER_BENCH_PID" 2>/dev/null || true
        _LLAMA_SERVER_BENCH_PID=""
    fi

    # Kill any remaining llama-server processes
    sudo killall llama-server 2>/dev/null || true
}
