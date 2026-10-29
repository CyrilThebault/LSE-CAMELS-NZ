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

# All workflow inputs are explicit command-line arguments.
if [[ "$#" -ne 4 || "$3" != "--timestep" ]]; then
  echo "Usage: bash $(basename "$0") <DIR_MAIN> <CONFIG_FILE> --timestep <daily|hourly>" >&2
  exit 2
fi

DIR_MAIN="$(cd "$1" && pwd -P)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
TIMESTEP="$4"

case "$TIMESTEP" in
  daily|hourly)
    ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing configuration: $CONFIG_FILE" >&2
  exit 2
fi


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

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/01_prepare/01_prepare_CAMELS_NZ.R" {} "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" :::: "$BASIN_FILE"