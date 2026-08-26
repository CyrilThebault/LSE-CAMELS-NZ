#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=11
#SBATCH --mem-per-cpu=4000
#SBATCH --time=12:00:00
#SBATCH -J lse_fold
#SBATCH --mail-type=FAIL

# Stop immediately on errors, unset variables and failed pipeline commands.
set -euo pipefail

# Load the software stack required by FUSE and the emulator workflow.
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

# Basin-level jobs are parallelised with GNU Parallel, so keep numerical
# libraries single-threaded to avoid oversubscribing the allocated CPUs.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1


# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:?Set EXPERIMENT_DIR to one fold directory}"

ZDECISION="${ZDECISION:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$zDecision)")}"
NREFINE="${NREFINE:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$nRefinementSteps)")}"

NCORES="${SLURM_CPUS_PER_TASK:-10}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_BASE="${TMPDIR:-/tmp}/lse_${SLURM_JOB_ID}"
mkdir -p "$TMP_BASE"


# ==============================================================================
# Initial emulator
#
# Step 0 is trained only from the immutable iter0 FUSE ensemble.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" 0 "$NCORES" "$DIR_MAIN"


# ==============================================================================
# Iterative refinement
#
# Candidate generation, FUSE evaluation and emulator retraining use TRAIN basins
# only. Test basins must never feed information back into the emulator.
# ==============================================================================

for ((step = 0; step < NREFINE; step++)); do

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$TMP_BASE/train_{}" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  next=$((step + 1))

  Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" "$next" "$NCORES" "$DIR_MAIN"

done


# ==============================================================================
# Final evaluation
#
# The final emulator is applied to the held-out basins. These FUSE evaluations
# are used only to assess regionalisation performance and never feed back into
# model training.
# ==============================================================================

FINAL_STEP="$NREFINE"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$FINAL_STEP" test "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$FINAL_STEP" test "$TMP_BASE/test_{}" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"