#!/usr/bin/env bash

#SBATCH --job-name=prepare_CAMELS_NZ
#SBATCH --account=rrg-mclark
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=logs/prepare/%x_%A_%a.log
#SBATCH --error=logs/prepare/%x_%A_%a.log

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

# ==============================================================================
# Workflow configuration
# ==============================================================================

ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:?This script must be submitted as a Slurm job array}"

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"

BASIN_FILE="$DIR_MAIN/config/basins.txt"

if [[ ! -f "$BASIN_FILE" ]]; then
  echo "Missing basin file: $BASIN_FILE" >&2
  exit 1
fi

# ==============================================================================
# Basin selection
# ==============================================================================

BASIN_ID="$(sed -n "${ARRAY_TASK_ID}p" "$BASIN_FILE")"

if [[ -z "$BASIN_ID" ]]; then
  echo "No basin found for array task ${ARRAY_TASK_ID}" >&2
  exit 1
fi

echo "Array task: ${ARRAY_TASK_ID}"
echo "Preparing basin: ${BASIN_ID}"

# ==============================================================================
# CAMELS-NZ preparation
# ==============================================================================

Rscript \
  "$DIR_MAIN/scripts/01_prepare/01_prepare_CAMELS_NZ.R" \
  "$BASIN_ID" \
  "$DIR_MAIN"
