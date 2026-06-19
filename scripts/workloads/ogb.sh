#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# OGB lives in a dedicated conda env (kept separate from the dataVis plotting
# env) because it pulls in the heavy torch + torch_geometric + ogb stack.
OGB_CONDA_ENV="${OGB_CONDA_ENV:-ogb}"
OGB_DIR="$CUR_PATH/ogb"
OGB_DATA_ROOT="${OGB_DATA_ROOT:-$OGB_DIR/dataset}"

# Resolve the conda env's python without needing `conda activate` (the wrapper
# execs this binary directly under numactl).
_ogb_env_python() {
    local base
    base=$(conda info --base 2>/dev/null) || return 1
    echo "$base/envs/$OGB_CONDA_ENV/bin/python"
}

config_ogb(){
    local _config_file="$1"
    local _workload="$2"

    num_threads="${OGB_NUM_THREADS:-8}"

    # The -w axis selects the dataset, which sets the working-set scale.
    case "$_workload" in
        products|ogbn-products)
            ogb_dataset="ogbn-products"
            ;;
        papers100M|ogbn-papers100M)
            ogb_dataset="ogbn-papers100M"
            ;;
        *)
            echo "ERROR: unknown ogb workload '$_workload'" >&2
            echo "Valid workloads: products (ogbn-products), papers100M (ogbn-papers100M)" >&2
            exit 1
            ;;
    esac

    # Run parameters (env-overridable, passed to ogb.py through the wrapper).
    ogb_epochs="${OGB_EPOCHS:-3}"
    ogb_batch_size="${OGB_BATCH_SIZE:-1024}"
    ogb_num_workers="${OGB_NUM_WORKERS:-0}"

    echo "=== OGB configuration ==="
    echo "Dataset:      $ogb_dataset"
    echo "Conda env:    $OGB_CONDA_ENV"
    echo "Epochs:       $ogb_epochs"
    echo "Batch size:   $ogb_batch_size"
    echo "DataLoader workers: $ogb_num_workers (0 = single OMP-threaded process)"
    echo "OMP threads:  $num_threads"
    echo "Data root:    $OGB_DATA_ROOT"
    echo "========================="
}

build_ogb(){
    local _workload="$1"

    if ! command -v conda >/dev/null 2>&1; then
        echo "ERROR: conda not found on PATH; required to build the '$OGB_CONDA_ENV' env." >&2
        exit 1
    fi

    local env_python
    env_python=$(_ogb_env_python) || { echo "ERROR: 'conda info --base' failed" >&2; exit 1; }

    # --- Create the env + install the CPU-only stack if not already present ---
    local need_install=0
    if [[ ! -x "$env_python" ]]; then
        need_install=1
    elif ! "$env_python" - <<'PY' >/dev/null 2>&1
import importlib.util, sys
missing = [m for m in ("torch", "torch_geometric", "ogb") if importlib.util.find_spec(m) is None]
sys.exit(1 if missing else 0)
PY
    then
        need_install=1
    fi

    if (( need_install )); then
        echo "Provisioning conda env '$OGB_CONDA_ENV' with CPU-only OGB stack..."
        if [[ ! -x "$env_python" ]]; then
            conda create -y -n "$OGB_CONDA_ENV" python=3.10
        fi
        env_python=$(_ogb_env_python)
        local env_pip="${env_python%/python}/pip"

        "$env_pip" install --upgrade pip
        # CPU-only torch wheels (no CUDA: execution is pinned to CPU).
        "$env_pip" install torch --index-url https://download.pytorch.org/whl/cpu

        local tver
        tver=$("$env_python" -c "import torch; print(torch.__version__.split('+')[0])")
        echo "Installed torch $tver; fetching matching PyG sparse ops..."

        "$env_pip" install torch_geometric
        # NeighborLoader needs pyg-lib (or torch-sparse) for the C++ neighbor
        # sampler; pull the wheels matching this torch version (CPU build).
        "$env_pip" install pyg-lib torch-scatter torch-sparse \
            -f "https://data.pyg.org/whl/torch-${tver}+cpu.html"
        "$env_pip" install ogb
    else
        echo "Reusing conda env '$OGB_CONDA_ENV' at $(dirname "$(dirname "$env_python")")"
    fi

    # --- Pre-download / pre-process the dataset OUTSIDE the timed run ---
    # PygNodePropPredDataset stores under root/<name-with-underscores>/, with the
    # final tensors under processed/.  Check the processed dir (not just the
    # parent) so a partial/aborted download doesn't get mistaken for "ready".
    local ds_dir="$OGB_DATA_ROOT/${ogb_dataset//-/_}"
    local ds_processed="$ds_dir/processed"
    if [[ ! -d "$ds_processed" || -z "$(ls -A "$ds_processed" 2>/dev/null)" ]]; then
        if [[ "$ogb_dataset" == "ogbn-papers100M" ]]; then
            echo "[WARN] $ogb_dataset is ~60GB download and needs ~100GB+ RAM to load."
        fi
        echo "Downloading + processing $ogb_dataset into $OGB_DATA_ROOT ..."
        mkdir -p "$OGB_DATA_ROOT"
        OGB_DATASET="$ogb_dataset" OGB_DATA_ROOT="$OGB_DATA_ROOT" \
            "$env_python" - <<'PY'
import os
import torch
# torch >=2.6 defaults torch.load(weights_only=True), which rejects the
# torch_geometric globals OGB writes into the processed .pt; restore permissive
# load (the dataset is generated locally here, so it's trusted).
_orig_load = torch.load
torch.load = lambda *a, **k: _orig_load(*a, **{**k, "weights_only": False})
# ogb prompts interactively (input() y/N) for downloads >1GB, which raises
# EOFError under a non-interactive heredoc. Auto-accept since the harness has
# already decided to fetch this dataset.
import ogb.utils.url as _ogb_url
_ogb_url.decide_download = lambda url: True
from ogb.nodeproppred import PygNodePropPredDataset
ds = PygNodePropPredDataset(name=os.environ["OGB_DATASET"], root=os.environ["OGB_DATA_ROOT"])
_ = ds[0]
ds.get_idx_split()
print("dataset ready")
PY
    else
        echo "Reusing dataset at $ds_dir"
    fi
}

run_ogb(){
    local workload="$1"

    generate_workload_filenames "$workload"

    local env_python
    env_python=$(_ogb_env_python)

    local extra_env="export OGB_DATASET=\"$ogb_dataset\"
export OGB_DATA_ROOT=\"$OGB_DATA_ROOT\"
export OGB_EPOCHS=\"$ogb_epochs\"
export OGB_BATCH_SIZE=\"$ogb_batch_size\"
export OGB_NUM_WORKERS=\"$ogb_num_workers\"
export OMP_NUM_THREADS=\"$num_threads\"
export MKL_NUM_THREADS=\"$num_threads\""

    # Run from the ogb dir so relative dataset paths resolve consistently.
    # NB: the script is ogb_gnn.py (not ogb.py) to avoid shadowing the installed
    # `ogb` package when cwd is the ogb dir.
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$env_python" \
        "$OGB_DIR/ogb_gnn.py" "$extra_env" "$OGB_DIR"

    # -p 0: prefer NUMA node 0 but allow spill so memory-tiering policies engage.
    run_workload_standard "--cpunodebind=0 -p 0"

    start_bwmon
}

clean_ogb(){
    stop_bwmon
    return
}
