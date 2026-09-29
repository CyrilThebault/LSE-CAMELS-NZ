#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=20G
#SBATCH --time=04:00:00
#SBATCH -J flood_catalogue
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/floods/%x_%j.log
#SBATCH --error=logs/floods/%x_%j.log

set -euo pipefail

# ==============================================================================
# ARC software environment
# ==============================================================================

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
