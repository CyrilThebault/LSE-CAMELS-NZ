#!/bin/bash

#SBATCH --job-name=flood_review
#SBATCH --account=rrg-mclark
#SBATCH --output=logs/floods/%x_%j.log
#SBATCH --error=logs/floods/%x_%j.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=04:00:00
#SBATCH --mail-type=FAIL

set -euo pipefail

# ==============================================================================
# FIR software environment
# ==============================================================================

module --force purge
module load StdEnv/2023
module load gcc/12.3
module load cmake/3.31.0
module load hdf5/1.14.6
module load netcdf/4.9.3
module load netcdf-fortran/4.6.1
module load r/4.4.0

export HDF5_INCLUDE_DIR="$EBROOTHDF5/include"
export HDF5_LIB_DIR="$EBROOTHDF5/lib"

# One R process is launched per basin; keep each process single-threaded.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN to the LSE-CAMELS-NZ repository root}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE to the experiment configuration file}"

[[ -f "$CONFIG_FILE" ]] || {
  echo "Missing configuration file: $CONFIG_FILE" >&2
  exit 1
}
NCORES="${NCORES:-${SLURM_CPUS_PER_TASK:-1}}"

SCRIPT="$DIR_MAIN/scripts/01_prepare/floods/02_plot_observed_flood_catalogue.R"
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
if [[ -z "${BASIN_IDS:-}" ]]; then
  [[ -f "$BASIN_FILE" ]] || { echo "Missing basin file: $BASIN_FILE" >&2; exit 1; }
fi


if [[ -n "${BASIN_IDS:-}" ]]; then
  BASINS="$(printf '%s\n' "$BASIN_IDS" | tr ', ' '\n\n' | awk 'NF')"
else
  BASINS="$(awk 'NF && $1 !~ /^#/ {print $1}' "$BASIN_FILE")"
fi

[[ -n "$BASINS" ]] || { echo "No basin IDs found." >&2; exit 1; }

# Check all destination PDFs before starting parallel processing.
existing_pdfs=()

while IFS= read -r ID; do
  [[ -n "$ID" ]] || continue

  pdf_file="$OUT_DIR/${ID}${PDF_SUFFIX}"

  if [[ -e "$pdf_file" || -L "$pdf_file" ]]; then
    existing_pdfs+=("$pdf_file")
  fi
done <<< "$BASINS"

if (( ${#existing_pdfs[@]} > 0 )); then
  printf 'Existing flood review PDF(s):\n' >&2
  printf '%s\n' "${existing_pdfs[@]}" >&2
  printf 'No PDFs were generated.\n' >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

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
    CONFIG_FILE="$6"

    echo "[review] basin $ID"

    Rscript \
      "$SCRIPT" \
      "$CONFIG_FILE" \
      "$DIR_MAIN" \
      "$EVENTS_FILE" \
      "$ID" \
      "$OUT_DIR/${ID}${PDF_SUFFIX}"
  ' _ {} "$DIR_MAIN" "$OUT_DIR" "$SCRIPT" "$EVENTS_FILE" "$CONFIG_FILE"

echo "Observed flood reviews written to:"
echo "  $OUT_DIR"
