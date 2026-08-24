#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem-per-cpu=4000
#SBATCH --time=12:00:00
#SBATCH -J lse_iter0
#SBATCH --mail-type=FAIL

# Stop on errors, unset variables and failed commands in pipelines.
set -euo pipefail

# Load the software stack required by FUSE and the R workflow.
module purge
module load lib/netcdf/4.9.2
module load R/4.3.1

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

# Convert config/basins.txt to the simple one-ID-per-line format expected by
# GNU Parallel. read_basin_ids() supports both accepted basin-file formats.
Rscript -e "source('$DIR_MAIN/scripts/functions/basins.R'); writeLines(read_basin_ids('$DIR_MAIN/config/basins.txt'), '$TMP_BASE/basins.ids')"


# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" {} "$ZDECISION" "$TMP_BASE/{}" "$DIR_MAIN" :::: "$TMP_BASE/basins.ids"