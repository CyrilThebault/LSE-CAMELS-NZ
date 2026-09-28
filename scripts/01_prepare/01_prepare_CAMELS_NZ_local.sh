#!/usr/bin/env bash

# Stop on errors, unset variables and failed commands in pipelines.
set -euo pipefail

# Each basin is prepared independently with GNU Parallel.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"

NCORES="${NCORES:-4}"

BASIN_FILE="$DIR_MAIN/config/basins.txt"

if [[ ! -f "$BASIN_FILE" ]]; then
  echo "Missing basin file: $BASIN_FILE" >&2
  exit 1
fi

# ==============================================================================
# CAMELS-NZ preparation
#
# Each basin is prepared independently and writes its own forcing files.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/01_prepare/01_prepare_CAMELS_NZ.R" {} "$CONFIG_FILE" "$DIR_MAIN" :::: "$BASIN_FILE"