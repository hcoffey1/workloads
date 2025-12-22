#!/bin/bash
set -euo pipefail

# Root directory containing the result folders (edit if needed)
ROOT_DIR="${1:-.}"

# Output file
OUT_FILE="log.txt"

# Toggle normalization of directory names for cleaner headers:
#   0 -> use raw directory names (e.g., results_lru_0)
#   1 -> normalized (e.g., lru, lfu, hybrid_2G, hybrid_512M)
NORMALIZE_NAMES=1

normalize() {
  local d="$1"
  # Strip leading "results_" and trailing "_0" if present
  d="${d#results_}"
  d="${d%_0}"
  # Convert to lowercase except keep capitalization in units if present
  # Handle specific cases to match your example style:
  # results_hybrid_2G_0 -> hybrid2g (your example), or hybrid_2G (cleaner).
  # We'll default to "hybrid_2G" (cleaner); uncomment next line to match "hybrid2g".
  #
  # d="$(echo "$d" | tr '[:upper:]' '[:lower:]' | sed 's/_//g')"   # -> hybrid2g style
  #
  # Keep underscores, preserve unit suffix (2G/512M) casing:
  # Make base lowercase but preserve suffix:
  if [[ "$d" =~ ^([^0-9]+)_(.*)$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local suf="${BASH_REMATCH[2]}"
    base="$(echo "$base" | tr '[:upper:]' '[:lower:]')"
    d="${base}_${suf}"
  else
    d="$(echo "$d" | tr '[:upper:]' '[:lower:]')"
  fi
  echo "$d"
}

echo "Writing to ${OUT_FILE}"
: > "$OUT_FILE"  # truncate

# Find immediate subdirectories that start with "results_"
mapfile -t DIRS < <(find "$ROOT_DIR" -maxdepth 1 -type d -name 'results_*' | sort)

if [[ ${#DIRS[@]} -eq 0 ]]; then
  echo "No 'results_*' directories found under ${ROOT_DIR}" >&2
  exit 1
fi

for dir in "${DIRS[@]}"; do
  raw_header="$(basename "$dir")"
  if [[ "$NORMALIZE_NAMES" -eq 1 ]]; then
    header="$(normalize "$raw_header")"
  else
    header="$raw_header"
  fi

  echo "$header" >> "$OUT_FILE"

  # Gather all stdout files within the directory
  mapfile -t FILES < <(find "$dir" -type f -name '*_stdout.txt' | sort)
  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "  (no stdout files)" >> "$OUT_FILE"
    echo >> "$OUT_FILE"
    continue
  fi

  # Extract lines matching "Baseline Total time"
  # Preserve original grep -ni formatting (line numbers and file content)
  for f in "${FILES[@]}"; do
    # Only print matches; suppress filenames for cleaner output to match your example
    # If you want to include filenames, add -H to grep
    grep -ni "Baseline Total time" "$f" >> "$OUT_FILE" || true
  done

  echo >> "$OUT_FILE"
done


