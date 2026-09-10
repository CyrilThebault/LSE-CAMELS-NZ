#!/usr/bin/env bash
#SBATCH --job-name=prepare_CAMELS_NZ
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=logs/prepare/%x_%A_%a.log
#SBATCH --error=logs/prepare/%x_%A_%a.log

# Stop on errors, unset variables and failed pipeline commands.
set -euo pipefail

# Load the software stack required by the R workflow.
. /work/comphyd_lab/local/modules/spack/2024v5/lmod-init-bash

module purge
module unuse $MODULEPATH
module use /work/comphyd_lab/local/modules/spack/2024v5/modules/linux-rocky8-x86_64/Core/

module load gcc/14.2.0
module load cmake/3.30.2
module load hdf5/1.14.3
module load netcdf-c/4.9.2
module load netcdf-fortran/4.6.1
module load r/4.4.1

ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:?This script must be submitted as a Slurm job array}"

# ==============================================================================
# Workflow configuration
# ==============================================================================

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

Rscript "$DIR_MAIN/scripts/01_prepare/01_prepare_CAMELS_NZ.R" "$BASIN_ID" "$DIR_MAIN"