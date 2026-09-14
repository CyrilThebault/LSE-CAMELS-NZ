#!/usr/bin/env bash

# Stop immediately on errors, unset variables and failed pipeline commands.
set -euo pipefail

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

NCORES="${NCORES:-4}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_BASE="${TMPDIR:-/tmp}/lse"
mkdir -p "$TMP_BASE"


# ==============================================================================
# Initial emulator
#
# Step 0 is trained only from the immutable iter0 FUSE ensemble. It is then
# evaluated on the held-out basins before any refinement. Test-basin results are
# used only for evaluation and never feed back into model training.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" 0 "$NCORES" "$DIR_MAIN"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$TMP_BASE/test_{}" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

# ==============================================================================
# Iterative refinement
#
# Candidate generation, FUSE evaluation and emulator retraining use TRAIN basins
# only. After each retraining step, the updated emulator is evaluated on the
# held-out basins. Test basins never feed information back into the emulator.
# ==============================================================================

for ((step = 0; step < NREFINE; step++)); do

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$TMP_BASE/train_{}" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/train_basins.txt"

  next=$((step + 1))

  Rscript "$DIR_MAIN/scripts/03_emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" "$next" "$NCORES" "$DIR_MAIN"

  # Evaluate the newly refined emulator on test basins.
  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/03_emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$TMP_BASE/test_{}" "$DIR_MAIN" :::: "$EXPERIMENT_DIR/test_basins.txt"

done
