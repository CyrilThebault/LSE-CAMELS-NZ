#!/usr/bin/env bash

# Stop immediately on errors, unset variables and failed pipeline commands.
set -euo pipefail

# Explicit workflow options.
usage() {
  echo "Usage: bash run_LSE_split_local.sh --timestep <daily|hourly> [--zdecision <value>] [--resume]" >&2
  exit 2
}

if [[ $# -lt 2 || "$1" != "--timestep" ]]; then
  usage
fi

TIMESTEP="$2"
shift 2

case "$TIMESTEP" in
  daily|hourly) ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac

ZDECISION_OVERRIDE=""
RESUME_ARGS=()

while (( $# > 0 )); do
  case "$1" in
    --zdecision)
      if (( $# < 2 )) || [[ -n "$ZDECISION_OVERRIDE" ]]; then
        usage
      fi
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        echo "Invalid --zdecision: expected an integer" >&2
        exit 2
      fi
      ZDECISION_OVERRIDE="$2"
      shift 2
      ;;
    --resume)
      if (( ${#RESUME_ARGS[@]} > 0 )); then
        usage
      fi
      RESUME_ARGS=(--resume)
      shift
      ;;
    *)
      usage
      ;;
  esac
done


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

EXPERIMENT_DIR="${EXPERIMENT_DIR:?Set EXPERIMENT_DIR to one fold directory}"

CONFIG_VALUES="$(
  Rscript - "$DIR_MAIN" "$CONFIG_FILE" "$TIMESTEP" <<'RS'
args <- commandArgs(trailingOnly = TRUE)
source(file.path(args[1], "scripts/functions/common.R"))
experiment <- load_workflow_config(
  args[2], timestep = args[3]
)
configured <- experiment$emulators
requested <- Sys.getenv("EMULATORS", unset = "")

selected <- if (nzchar(requested)) {
  if (grepl(",[[:space:]]*$", requested)) {
    stop("Invalid EMULATORS: trailing comma")
  }
  trimws(strsplit(requested, ",", fixed = TRUE)[[1L]])
} else {
  configured
}

if (!length(selected) ||
    anyNA(selected) ||
    any(!nzchar(selected)) ||
    anyDuplicated(selected) ||
    any(!selected %in% configured)) {
  stop("Invalid or duplicate EMULATORS selection")
}

cat(
  experiment$zDecision,
  experiment$nRefinementSteps,
  paste(selected, collapse = ","),
  sep = " "
)
RS
)"

read -r CONFIG_ZDECISION CONFIG_NREFINE SELECTED_EMULATORS <<< "$CONFIG_VALUES"

ZDECISION="${ZDECISION_OVERRIDE:-$CONFIG_ZDECISION}"
NREFINE="${NREFINE:-$CONFIG_NREFINE}"

NCORES="${NCORES:-4}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/lse.XXXXXXXX")


# ==============================================================================
# Initial emulator
#
# Step 0 is trained only from the immutable iter0 FUSE ensemble. It is then
# evaluated on the held-out basins before any refinement. Test-basin results are
# used only for evaluation and never feed back into model training.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/04_simulations/emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" 0 "$NCORES" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}"

parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/test_basins.txt"

parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" 0 test "$TMP_BASE/test_step0_{}" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/test_basins.txt"

# ==============================================================================
# Iterative refinement
#
# Candidate generation, FUSE evaluation and emulator retraining use TRAIN basins
# only. After each retraining step, the updated emulator is evaluated on the
# held-out basins. Test basins never feed information back into the emulator.
# ==============================================================================

for ((step = 0; step < NREFINE; step++)); do

  parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/train_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$step" train "$TMP_BASE/train_step${step}_{}" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/train_basins.txt"

  next=$((step + 1))

  Rscript "$DIR_MAIN/scripts/04_simulations/emulator/01_train_emulator.R" "$EXPERIMENT_DIR" "$ZDECISION" "$next" "$NCORES" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}"

  # Evaluate the newly refined emulator on test basins.
  parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/02_search_parameter_space.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/test_basins.txt"

  parallel -j "$NCORES" --line-buffer --tag -- Rscript "$DIR_MAIN/scripts/04_simulations/emulator/03_run_FUSE_candidates.R" {} "$EXPERIMENT_DIR" "$ZDECISION" "$next" test "$TMP_BASE/test_step${next}_{}" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" --emulator "$SELECTED_EMULATORS" "${RESUME_ARGS[@]}" :::: "$EXPERIMENT_DIR/test_basins.txt"

done
