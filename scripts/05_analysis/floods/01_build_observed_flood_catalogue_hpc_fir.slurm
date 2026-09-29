#!/bin/bash
#SBATCH --job-name=flood_catalogue
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

# Basin-level parallelism is handled by R; keep each worker single-threaded.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1


# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN to the LSE-CAMELS-NZ repository root}"
NCORES="${NCORES:-${SLURM_CPUS_PER_TASK:-1}}"


# ==============================================================================
# Build canonical observed flood catalogue
# ==============================================================================

Rscript \
  "$DIR_MAIN/scripts/05_analysis/floods/01_build_observed_flood_catalogue.R" \
  "$DIR_MAIN" \
  "$NCORES"
