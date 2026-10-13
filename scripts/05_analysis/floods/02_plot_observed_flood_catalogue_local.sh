#!/usr/bin/env bash

set -euo pipefail

# One R process is launched per basin; keep each process single-threaded.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN to the LSE-CAMELS-NZ repository root}"
NCORES="${NCORES:-4}"

SCRIPT="$DIR_MAIN/scripts/05_analysis/floods/02_plot_observed_flood_catalogue.R"
BASIN_FILE="${BASIN_FILE:-$DIR_MAIN/config/basins.txt}"
EVENTS_FILE="${EVENTS_FILE:-$DIR_MAIN/data/flood/observed_flood_catalogue.csv}"
# Select default output directory and filename from the input catalogue.
if [[ "$(basename "$EVENTS_FILE")" == observed_flood_qc*.csv ]]; then
  DEFAULT_OUT_DIR="$DIR_MAIN/data/flood/qc/pdf"
  export PDF_SUFFIX="_observed_flood_qc_review.pdf"
else
  DEFAULT_OUT_DIR="$DIR_MAIN/data/flood/pdf"
  export PDF_SUFFIX="_observed_flood_review.pdf"
fi

OUT_DIR="${OUT_DIR:-$DEFAULT_OUT_DIR}"

[[ -f "$EVENTS_FILE" ]] || { echo "Missing events file: $EVENTS_FILE" >&2; exit 1; }
[[ -f "$SCRIPT" ]] || { echo "Missing script: $SCRIPT" >&2; exit 1; }
[[ -f "$BASIN_FILE" ]] || { echo "Missing basin file: $BASIN_FILE" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# BASIN_IDS can be used for a small test, e.g. BASIN_IDS="802 1316".
if [[ -n "${BASIN_IDS:-}" ]]; then
  BASINS="$(printf '%s\n' "$BASIN_IDS" | tr ', ' '\n\n' | awk 'NF')"
else
  BASINS="$(awk 'NF && $1 !~ /^#/ {print $1}' "$BASIN_FILE")"
fi

[[ -n "$BASINS" ]] || { echo "No basin IDs found." >&2; exit 1; }

# ==============================================================================
# Review observed flood catalogue
# ==============================================================================

printf '%s\n' "$BASINS" |
  xargs -P "$NCORES" -I {} bash -c '
    ID="$1"
    DIR_MAIN="$2"
    OUT_DIR="$3"
    SCRIPT="$4"
    EVENTS_FILE="$5"

    echo "[review] basin $ID"

    Rscript \
      "$SCRIPT" \
      "$DIR_MAIN" \
      "$EVENTS_FILE" \
      "$ID" \
      "$OUT_DIR/${ID}${PDF_SUFFIX}"
  ' _ {} "$DIR_MAIN" "$OUT_DIR" "$SCRIPT" "$EVENTS_FILE"

echo "Observed flood reviews written to:"
echo "  $OUT_DIR"
