#!/bin/bash
#SBATCH --job-name=iter0
#SBATCH --account=rrg-mclark
#SBATCH --output=logs/iter0/%x_%A_%a.log
#SBATCH --error=logs/iter0/%x_%A_%a.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=01-00:00:00
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

# Each basin is run independently with GNU Parallel, so keep numerical libraries
# single-threaded to avoid oversubscribing the allocated CPUs.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:?This script must be submitted as a Slurm job array}"

# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"

ZDECISION="${ZDECISION:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$zDecision)")}"

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
echo "Running iter0 for basin: ${BASIN_ID}"

# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_ROOT="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
TMP_BASE="$TMP_ROOT/lse_iter0_${SLURM_ARRAY_JOB_ID}_${ARRAY_TASK_ID}"
mkdir -p "$TMP_BASE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" "$BASIN_ID" "$ZDECISION" "$TMP_BASE" "$DIR_MAIN"
