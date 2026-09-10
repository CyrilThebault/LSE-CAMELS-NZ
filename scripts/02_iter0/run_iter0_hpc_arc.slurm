#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem-per-cpu=4000
#SBATCH --time=12:00:00
#SBATCH -J lse_iter0
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/iter0/%x_%j.log
#SBATCH --error=logs/iter0/%x_%j.log

# Stop on errors, unset variables and failed commands in pipelines.
set -euo pipefail

# Load the software stack required by FUSE and the R workflow.
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

# Each basin is run independently with GNU Parallel, so keep numerical libraries
# single-threaded to avoid oversubscribing the allocated CPUs.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1


# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"

ZDECISION="${ZDECISION:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$zDecision)")}"

NCORES="${SLURM_CPUS_PER_TASK:-10}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_BASE="${TMPDIR:-/tmp}/lse_iter0_${SLURM_JOB_ID}"
mkdir -p "$TMP_BASE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" {} "$ZDECISION" "$TMP_BASE/{}" "$DIR_MAIN" :::: "$DIR_MAIN/config/basins.txt"
