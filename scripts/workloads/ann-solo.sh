#!/bin/bash

source "$CUR_PATH/scripts/workload_utils.sh"

ANN_SOLO_DIR="$CUR_PATH/ANN-SoLo"
ANN_SOLO_SRC="$ANN_SOLO_DIR/src"
ANN_SOLO_VENV="$ANN_SOLO_DIR/.venv"
ANN_SOLO_DATA_ROOT="$ANN_SOLO_DIR/data/generated"
ANN_SOLO_CACHE_ROOT="$ANN_SOLO_DIR/.cache"

select_ann_solo_python() {
    if [[ -n "${ANN_SOLO_PYTHON:-}" ]]; then
        echo "$ANN_SOLO_PYTHON"
        return
    fi
    # Try Python versions in order of compatibility with lancedb/pyarrow
    for py_version in python3.9 python3.10 python3.11 python3.12; do
        if command -v "$py_version" >/dev/null 2>&1; then
            echo "$py_version"
            return
        fi
    done
    echo "ERROR: No compatible Python found. ANN-SoLo requires Python 3.9-3.12. Python 3.13+ is not compatible with lancedb." >&2
    echo "python3"  # Fallback, but will likely fail
}

prepare_ann_solo_dataset() {
    local size="$1"
    local library_count query_multiplier

    case "$size" in
        toy)
            library_count=512
            query_multiplier=1
            ;;
        small)
            # Target ~5-8 GB: 256K spectra library
            library_count=262144
            query_multiplier=1
            ;;
        medium)
            # Target ~10-15 GB: 512K spectra library
            library_count=524288
            query_multiplier=1
            ;;
        large)
            # Target ~20-25 GB: 1M spectra library
            library_count=1048576
            query_multiplier=1
            ;;
        *)
            echo "ERROR: Unknown ANN_SOLO_SIZE '$size'" >&2
            return 1
            ;;
    esac

    if [[ -n "$ANN_SOLO_LIBRARY_COUNT_OVERRIDE" ]]; then
        library_count="$ANN_SOLO_LIBRARY_COUNT_OVERRIDE"
    fi
    if [[ -n "$ANN_SOLO_QUERY_MULTIPLIER" ]]; then
        query_multiplier="$ANN_SOLO_QUERY_MULTIPLIER"
    fi

    local query_count=$(( library_count * query_multiplier ))
    local peak_count="${ANN_SOLO_PEAKS_PER_SPECTRUM:-60}"
    local seed="${ANN_SOLO_RANDOM_SEED:-1337}"

    local base_dir="$ANN_SOLO_DATA_ROOT/$size"
    local library_file="$base_dir/library_${size}.mgf"
    local query_file="$base_dir/query_${size}.mgf"
    local meta_file="$base_dir/dataset.meta"

    local regenerate=0
    if [[ "${ANN_SOLO_FORCE_REGEN:-0}" == "1" ]]; then
        regenerate=1
    elif [[ ! -f "$library_file" || ! -f "$query_file" || ! -f "$meta_file" ]]; then
        regenerate=1
    else
        # shellcheck disable=SC1090
        source "$meta_file"
        if [[ "${ANN_SOLO_META_LIBRARY_COUNT:-0}" -ne "$library_count" || \
              "${ANN_SOLO_META_QUERY_COUNT:-0}" -ne "$query_count" || \
              "${ANN_SOLO_META_PEAK_COUNT:-0}" -ne "$peak_count" ]]; then
            regenerate=1
        fi
    fi

    if (( regenerate )); then
        echo "Generating ANN-SoLo dataset ($size: library=$library_count, query=$query_count)"
        mkdir -p "$base_dir"
        "$ANN_SOLO_VENV/bin/python" - <<PY
import random
import pathlib

library_count = $library_count
query_count = $query_count
peak_count = $peak_count
seed = $seed
alphabet = "ACDEFGHIKLMNPQRSTVWY"

rng = random.Random(seed)

def random_peptide():
    length = rng.randint(7, 20)
    return "".join(rng.choice(alphabet) for _ in range(length))

def generate_spectrum(seq, index):
    charge = rng.choice((2, 3))
    precursor = 400.0 + 2.3 * index + rng.random() * 5.0 + charge * 50.0
    rt = rng.random() * 1800.0
    peaks = []
    base = rng.random() * 100.0 + 100.0
    for i in range(peak_count):
        mass = base + i * rng.uniform(1.0, 2.0) + rng.uniform(-0.05, 0.05)
        intensity = rng.random() ** 2 * 1000.0
        peaks.append((mass, intensity))
    return charge, precursor, rt, peaks

lib_path = pathlib.Path("$library_file")
qry_path = pathlib.Path("$query_file")
lib_path.parent.mkdir(parents=True, exist_ok=True)

library = []
with lib_path.open("w", encoding="ascii") as fout:
    for idx in range(library_count):
        seq = random_peptide()
        charge, precursor, rt, peaks = generate_spectrum(seq, idx)
        title = f"LIB_{idx:07d}"
        library.append((seq, charge, precursor, rt, peaks))
        fout.write("BEGIN IONS\n")
        fout.write(f"TITLE={title}\n")
        fout.write(f"SEQ={seq}\n")
        fout.write(f"PEPMASS={precursor:.6f}\n")
        fout.write(f"CHARGE={charge}+\n")
        fout.write(f"RTINSECONDS={rt:.2f}\n")
        for mass, intensity in peaks:
            fout.write(f"{mass:.6f} {intensity:.6f}\n")
        fout.write("END IONS\n\n")

with qry_path.open("w", encoding="ascii") as fout:
    for idx in range(query_count):
        seq, charge, precursor, rt, peaks = library[idx % len(library)]
        fout.write("BEGIN IONS\n")
        fout.write(f"TITLE=QUERY_{idx:07d}\n")
        fout.write(f"SEQ={seq}\n")
        fout.write(f"PEPMASS={precursor:.6f}\n")
        fout.write(f"CHARGE={charge}+\n")
        fout.write(f"RTINSECONDS={rt:.2f}\n")
        for mass, intensity in peaks:
            pert_mass = mass + rng.uniform(-0.01, 0.01)
            pert_intensity = intensity * (0.9 + rng.random() * 0.2)
            fout.write(f"{pert_mass:.6f} {pert_intensity:.6f}\n")
        fout.write("END IONS\n\n")
PY
        cat > "$meta_file" <<EOF
ANN_SOLO_META_LIBRARY_COUNT=$library_count
ANN_SOLO_META_QUERY_COUNT=$query_count
ANN_SOLO_META_PEAK_COUNT=$peak_count
ANN_SOLO_META_RANDOM_SEED=$seed
EOF
    else
        echo "Reusing ANN-SoLo dataset: $base_dir"
    fi

    ANN_SOLO_LIBRARY_FILE="$library_file"
    ANN_SOLO_QUERY_FILE="$query_file"
    export ANN_SOLO_LIBRARY_FILE ANN_SOLO_QUERY_FILE
}

config_ann-solo(){
    local config_file="$1"
    local workload="$2"

    local library_override="${ANN_SOLO_LIBRARY_COUNT:-}"; unset ANN_SOLO_LIBRARY_COUNT

    ANN_SOLO_SIZE="${ANN_SOLO_SIZE:-toy}"
    ANN_SOLO_MODE="${ANN_SOLO_MODE:-ann}"
    ANN_SOLO_QUERY_MULTIPLIER="${ANN_SOLO_QUERY_MULTIPLIER:-1}"
    ANN_SOLO_PEAKS_PER_SPECTRUM="${ANN_SOLO_PEAKS_PER_SPECTRUM:-60}"
    ANN_SOLO_RANDOM_SEED="${ANN_SOLO_RANDOM_SEED:-1337}"
    ANN_SOLO_PRECURSOR_TOLERANCE_MASS="${ANN_SOLO_PRECURSOR_TOLERANCE_MASS:-20}"
    ANN_SOLO_PRECURSOR_TOLERANCE_MODE="${ANN_SOLO_PRECURSOR_TOLERANCE_MODE:-ppm}"
    ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN="${ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN:-}"
    ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN="${ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN:-}"
    ANN_SOLO_FRAGMENT_MZ_TOLERANCE="${ANN_SOLO_FRAGMENT_MZ_TOLERANCE:-0.02}"
    ANN_SOLO_FRAGMENT_TOL_MODE="${ANN_SOLO_FRAGMENT_TOL_MODE:-Da}"
    ANN_SOLO_ALLOW_PEAK_SHIFTS="${ANN_SOLO_ALLOW_PEAK_SHIFTS:-0}"
    ANN_SOLO_REMOVE_PRECURSOR="${ANN_SOLO_REMOVE_PRECURSOR:-0}"
    ANN_SOLO_REMOVE_PRECURSOR_TOL="${ANN_SOLO_REMOVE_PRECURSOR_TOL:-0}"
    ANN_SOLO_NO_GPU="${ANN_SOLO_NO_GPU:-1}"
    ANN_SOLO_BIN_SIZE="${ANN_SOLO_BIN_SIZE:-0.04}"
    ANN_SOLO_HASH_LEN="${ANN_SOLO_HASH_LEN:-800}"
    ANN_SOLO_NUM_CANDIDATES="${ANN_SOLO_NUM_CANDIDATES:-256}"
    ANN_SOLO_NUM_LIST="${ANN_SOLO_NUM_LIST:-128}"
    ANN_SOLO_NUM_PROBE="${ANN_SOLO_NUM_PROBE:-64}"
    ANN_SOLO_BATCH_SIZE="${ANN_SOLO_BATCH_SIZE:-4096}"
    ANN_SOLO_FDR="${ANN_SOLO_FDR:-0.01}"
    ANN_SOLO_FDR_MIN_GROUP_SIZE="${ANN_SOLO_FDR_MIN_GROUP_SIZE:-50}"
    ANN_SOLO_MODEL="${ANN_SOLO_MODEL:-none}"
    ANN_SOLO_SCALING="${ANN_SOLO_SCALING:-rank}"
    ANN_SOLO_MIN_PEAKS="${ANN_SOLO_MIN_PEAKS:-10}"
    ANN_SOLO_MAX_PEAKS_USED="${ANN_SOLO_MAX_PEAKS_USED:-75}"
    ANN_SOLO_MAX_PEAKS_USED_LIBRARY="${ANN_SOLO_MAX_PEAKS_USED_LIBRARY:-75}"
    ANN_SOLO_MIN_MZ="${ANN_SOLO_MIN_MZ:-50}"
    ANN_SOLO_MAX_MZ="${ANN_SOLO_MAX_MZ:-2000}"
    ANN_SOLO_MIN_MZ_RANGE="${ANN_SOLO_MIN_MZ_RANGE:-50}"
    ANN_SOLO_THREADS="${ANN_SOLO_THREADS:-$(nproc)}"
    ANN_SOLO_LIBRARY_COUNT_OVERRIDE="$library_override"

    export ANN_SOLO_SIZE ANN_SOLO_MODE ANN_SOLO_QUERY_MULTIPLIER \
           ANN_SOLO_PEAKS_PER_SPECTRUM ANN_SOLO_RANDOM_SEED \
           ANN_SOLO_PRECURSOR_TOLERANCE_MASS ANN_SOLO_PRECURSOR_TOLERANCE_MODE \
           ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN \
           ANN_SOLO_FRAGMENT_MZ_TOLERANCE ANN_SOLO_FRAGMENT_TOL_MODE \
           ANN_SOLO_ALLOW_PEAK_SHIFTS ANN_SOLO_REMOVE_PRECURSOR \
           ANN_SOLO_REMOVE_PRECURSOR_TOL ANN_SOLO_NO_GPU ANN_SOLO_BIN_SIZE \
           ANN_SOLO_HASH_LEN ANN_SOLO_NUM_CANDIDATES ANN_SOLO_NUM_LIST \
           ANN_SOLO_NUM_PROBE ANN_SOLO_BATCH_SIZE ANN_SOLO_FDR \
           ANN_SOLO_FDR_MIN_GROUP_SIZE ANN_SOLO_MODEL ANN_SOLO_SCALING \
           ANN_SOLO_MIN_PEAKS ANN_SOLO_MAX_PEAKS_USED \
           ANN_SOLO_MAX_PEAKS_USED_LIBRARY ANN_SOLO_MIN_MZ ANN_SOLO_MAX_MZ \
           ANN_SOLO_MIN_MZ_RANGE ANN_SOLO_THREADS ANN_SOLO_LIBRARY_COUNT_OVERRIDE ANN_SOLO_FORCE_REGEN

    echo "=== ANN-SoLo configuration ==="
    echo "Dataset size:      $ANN_SOLO_SIZE (toy=512, small=256K, medium=512K, large=1M spectra)"
    echo "Mode:              $ANN_SOLO_MODE"
    echo "Threads:           $ANN_SOLO_THREADS"
    echo "Precursor tol:     $ANN_SOLO_PRECURSOR_TOLERANCE_MASS $ANN_SOLO_PRECURSOR_TOLERANCE_MODE"
    if [[ -n "$ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN" ]]; then
        echo "Open precursor:    $ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN $ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN"
    fi
    echo "Fragment tol:      $ANN_SOLO_FRAGMENT_MZ_TOLERANCE $ANN_SOLO_FRAGMENT_TOL_MODE"
    echo "Candidates:        $ANN_SOLO_NUM_CANDIDATES (lists=$ANN_SOLO_NUM_LIST, probes=$ANN_SOLO_NUM_PROBE)"
    echo "Batch size:        $ANN_SOLO_BATCH_SIZE"
    echo "Library override:  ${ANN_SOLO_LIBRARY_COUNT_OVERRIDE:-auto}"
    echo "Query multiplier:  $ANN_SOLO_QUERY_MULTIPLIER"
    echo "=============================="
}

build_ann-solo(){
    local workload="$1"

    mkdir -p "$ANN_SOLO_DIR" "$ANN_SOLO_CACHE_ROOT" "$ANN_SOLO_DATA_ROOT"

    local python_bin
    python_bin=$(select_ann_solo_python)

    if [[ ! -x "$ANN_SOLO_VENV/bin/python" ]]; then
        echo "Creating ANN-SoLo virtualenv using $python_bin"
        "$python_bin" -m venv "$ANN_SOLO_VENV"
        "$ANN_SOLO_VENV/bin/pip" install --upgrade pip setuptools wheel
        # Pin NumPy 1.x - pyarrow 14.x was compiled against NumPy 1.x
        "$ANN_SOLO_VENV/bin/pip" install "numpy>=1.21,<2.0"
        local faiss_pkg="${ANN_SOLO_FAISS_PACKAGE:-faiss-cpu}"
        if [[ -n "${ANN_SOLO_FAISS_VERSION:-}" ]]; then
            "$ANN_SOLO_VENV/bin/pip" install "$faiss_pkg==${ANN_SOLO_FAISS_VERSION}"
        else
            "$ANN_SOLO_VENV/bin/pip" install "$faiss_pkg"
        fi
        # Pin compatible versions: lancedb 0.3.x requires pyarrow <15
        "$ANN_SOLO_VENV/bin/pip" install "pyarrow>=14.0.1,<15.0" "lancedb>=0.3.0,<0.4.0"
        "$ANN_SOLO_VENV/bin/pip" install ConfigArgParse Cython joblib matplotlib mmh3 "mokapot>=0.8.3" "numba>=0.41" numexpr pandas pyteomics scipy "spectrum_utils>=0.4.2" tqdm psims koinapy "tritonclient[grpc]"
    else
        echo "Reusing ANN-SoLo virtualenv at $ANN_SOLO_VENV"
        # Check if numpy/pyarrow/lancedb versions are compatible
        if ! "$ANN_SOLO_VENV/bin/python" - <<'PY'
import sys
try:
    import numpy as np
    import pyarrow as pa
    import lancedb
    # Check numpy version is < 2.0 for pyarrow 14.x compatibility
    np_version = tuple(int(x) for x in np.__version__.split('.')[:2])
    if np_version >= (2, 0):
        print(f"ERROR: numpy {np.__version__} is too new for pyarrow 14.x. Need numpy <2.0", file=sys.stderr)
        sys.exit(1)
    # Check pyarrow version is < 15 for lancedb 0.3.x compatibility
    pa_version = tuple(int(x) for x in pa.__version__.split('.')[:2])
    if pa_version >= (15, 0):
        print(f"ERROR: pyarrow {pa.__version__} is too new for lancedb. Need pyarrow <15", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
        then
            echo "WARNING: Incompatible numpy/pyarrow/lancedb versions detected. Reinstalling..."
            "$ANN_SOLO_VENV/bin/pip" uninstall -y numpy pyarrow lancedb
            "$ANN_SOLO_VENV/bin/pip" install "numpy>=1.21,<2.0"
            "$ANN_SOLO_VENV/bin/pip" install "pyarrow>=14.0.1,<15.0" "lancedb>=0.3.0,<0.4.0"
        fi
    fi

    if ! "$ANN_SOLO_VENV/bin/python" - <<'PY'
import importlib.util
import sys
missing = [
    mod for mod in ("koinapy", "tritonclient.grpc")
    if importlib.util.find_spec(mod) is None
]
sys.exit(0 if not missing else 1)
PY
    then
        "$ANN_SOLO_VENV/bin/pip" install koinapy "tritonclient[grpc]"
    fi

    "$ANN_SOLO_VENV/bin/python" - <<'PY'
import importlib, sys
modules = [
    "faiss",
    "lancedb",
    "pyarrow",
    "pyteomics",
    "numba",
    "numpy",
    "psims",
    "mokapot",
    "spectrum_utils",
    "configargparse",
    "koinapy",
    "tritonclient.grpc",
]
missing = [m for m in modules if importlib.util.find_spec(m) is None]
if missing:
    sys.exit("Missing ANN-SoLo dependencies: " + ", ".join(missing))
PY

    pushd "$ANN_SOLO_SRC" > /dev/null
    "$ANN_SOLO_VENV/bin/python" setup.py build_ext --inplace
    popd > /dev/null
}

run_ann-solo(){
    local workload="$1"

    generate_workload_filenames "$workload"

    prepare_ann_solo_dataset "$ANN_SOLO_SIZE" || return 1

    local result_prefix="$OUTPUT_DIR/${SUITE}_${WORKLOAD}_${ANN_SOLO_SIZE}"
    if [[ -n "$CURRENT_ITERATION" ]]; then
        result_prefix+="_iter${CURRENT_ITERATION}"
    fi
    ANN_SOLO_RESULT_FILE="${result_prefix}_results.mztab"
    export ANN_SOLO_RESULT_FILE

    local -a args
    args=(-m ann_solo.ann_solo
          "$ANN_SOLO_LIBRARY_FILE"
          "$ANN_SOLO_QUERY_FILE"
          "$ANN_SOLO_RESULT_FILE"
          --precursor_tolerance_mass "$ANN_SOLO_PRECURSOR_TOLERANCE_MASS"
          --precursor_tolerance_mode "$ANN_SOLO_PRECURSOR_TOLERANCE_MODE"
          --fragment_mz_tolerance "$ANN_SOLO_FRAGMENT_MZ_TOLERANCE"
          --fragment_tol_mode "$ANN_SOLO_FRAGMENT_TOL_MODE"
          --mode "$ANN_SOLO_MODE"
          --model "$ANN_SOLO_MODEL"
          --bin_size "$ANN_SOLO_BIN_SIZE"
          --hash_len "$ANN_SOLO_HASH_LEN"
          --num_candidates "$ANN_SOLO_NUM_CANDIDATES"
          --num_list "$ANN_SOLO_NUM_LIST"
          --num_probe "$ANN_SOLO_NUM_PROBE"
          --batch_size "$ANN_SOLO_BATCH_SIZE"
          --fdr "$ANN_SOLO_FDR"
          --fdr_min_group_size "$ANN_SOLO_FDR_MIN_GROUP_SIZE"
          --max_peaks_used "$ANN_SOLO_MAX_PEAKS_USED"
          --max_peaks_used_library "$ANN_SOLO_MAX_PEAKS_USED_LIBRARY"
          --min_peaks "$ANN_SOLO_MIN_PEAKS"
          --min_mz "$ANN_SOLO_MIN_MZ"
          --max_mz "$ANN_SOLO_MAX_MZ"
          --min_mz_range "$ANN_SOLO_MIN_MZ_RANGE"
          --scaling "$ANN_SOLO_SCALING")

    if [[ -n "$ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN" && -n "$ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN" ]]; then
        args+=(--precursor_tolerance_mass_open "$ANN_SOLO_PRECURSOR_TOLERANCE_MASS_OPEN")
        args+=(--precursor_tolerance_mode_open "$ANN_SOLO_PRECURSOR_TOLERANCE_MODE_OPEN")
    fi
    if [[ "$ANN_SOLO_ALLOW_PEAK_SHIFTS" == "1" ]]; then
        args+=(--allow_peak_shifts)
    fi
    if [[ "$ANN_SOLO_REMOVE_PRECURSOR" == "1" ]]; then
        args+=(--remove_precursor)
    fi
    if [[ "$ANN_SOLO_REMOVE_PRECURSOR_TOL" != "0" ]]; then
        args+=(--remove_precursor_tolerance "$ANN_SOLO_REMOVE_PRECURSOR_TOL")
    fi
    if [[ "$ANN_SOLO_NO_GPU" == "1" ]]; then
        args+=(--no_gpu)
    fi
    if [[ -n "${ANN_SOLO_EXTRA_FLAGS:-}" ]]; then
        args+=($ANN_SOLO_EXTRA_FLAGS)
    fi

    local python_bin="$ANN_SOLO_VENV/bin/python"
    local binary_args="${args[*]}"
    local extra_env="export PYTHONPATH=\"$ANN_SOLO_SRC:\${PYTHONPATH:-}\"
export OMP_NUM_THREADS=\"$ANN_SOLO_THREADS\""

    echo "Command preview: $python_bin $binary_args"
    echo "Library: $ANN_SOLO_LIBRARY_FILE"
    echo "Query:   $ANN_SOLO_QUERY_FILE"
    echo "Output:  $ANN_SOLO_RESULT_FILE"

    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$python_bin" "$binary_args" "$extra_env"

    run_workload_standard "--cpunodebind=0 --membind=0"

    start_bwmon
}

run_strace_ann-solo(){
    echo "ERROR: strace mode not implemented for ANN-SoLo" >&2
    exit 1
}

clean_ann-solo(){
    stop_bwmon
}
