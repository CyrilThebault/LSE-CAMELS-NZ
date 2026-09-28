#!/bin/bash
#SBATCH --job-name=lse_split
#SBATCH --account=rrg-mclark
#SBATCH --output=logs/emulator/%x_%j.log
#SBATCH --error=logs/emulator/%x_%j.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=86
#SBATCH --mem-per-cpu=4000
#SBATCH --time=1-00:00:00
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
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:?Set EXPERIMENT_DIR to one split directory}"

ZDECISION="${ZDECISION:-$(Rscript -e "source('${CONFIG_FILE}'); cat(experiment\$zDecision)")}"
NREFINE="${NREFINE:-$(Rscript -e "source('${CONFIG_FILE}'); cat(experiment\$nRefinementSteps)")}"

NCORES="${SLURM_CPUS_PER_TASK:-10}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_ROOT="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
TMP_BASE="$TMP_ROOT/lse_${SLURM_JOB_ID}"
mkdir -p "$TMP_BASE"


# ==============================================================================
# Initial emulator
#
# Step 0 is trained only from the immutable iter0 FUSE ensemble. It is then
# evaluated on the held-out basins before any refinement. Test-basin results are
# used only for evaluation and never feed back into model training.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" 0 "$NCORES" "$CONFIG_FILE" "$DIR_MAIN"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$TMP_BASE/test_{}" "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

# ==============================================================================
# Iterative refinement
#
# Candidate generation, FUSE evaluation and emulator retraining use TRAIN basins
# only. After each retraining step, the updated emulator is evaluated on the
# held-out basins. Test basins never feed information back into the emulator.
# ==============================================================================

for ((step = 0; step < NREFINE; step++)); do

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$TMP_BASE/train_{}" "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  next=$((step + 1))

  Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" "$next" "$NCORES" "$CONFIG_FILE" "$DIR_MAIN"

  # Evaluate the newly refined emulator on test basins.
  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$TMP_BASE/test_{}" "$CONFIG_FILE" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

done
