#!/bin/bash

set -euo pipefail



# ==============================================================================
# Submit all splits of one LSE experiment on FIR
#
# Example:
#   bash submit_LSE_experiment_hpc_fir.sh \
#     /project/6079554/thebault/ESNZ/02_DATA/LSE-CAMELS-NZ \
#     /project/6079554/thebault/ESNZ/02_DATA/LSE-CAMELS-NZ/config/experiment.R \
#     kfold --timestep hourly
#
# Optional environment override for refinements:
#   NREFINE=2 bash submit_LSE_experiment_hpc_fir.sh \
#     <DIR_MAIN> <CONFIG_FILE> <experiment> --timestep hourly --zdecision 126
# ==============================================================================

module --force purge
module load StdEnv/2023
module load r/4.4.0

usage() {
  echo "Usage: bash submit_LSE_experiment_hpc_fir.sh <DIR_MAIN> <CONFIG_FILE> <experiment> --timestep <daily|hourly> [--zdecision <value>]" >&2
  exit 2
}

if [[ $# -ne 5 && $# -ne 7 ]]; then
  usage
fi

if [[ "$4" != "--timestep" ]]; then
  usage
fi

TIMESTEP="$5"

case "$TIMESTEP" in
  daily|hourly) ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac

ZDECISION_OVERRIDE=""

if [[ $# -eq 7 ]]; then
  if [[ "$6" != "--zdecision" ]]; then
    usage
  fi

  if [[ ! "$7" =~ ^[0-9]+$ ]]; then
    echo "Invalid --zdecision: expected an integer" >&2
    exit 2
  fi

  ZDECISION_OVERRIDE="$7"
fi

DIR_MAIN="$(cd "$1" && pwd)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

EXPERIMENT="$3"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file does not exist:"
  echo "  $CONFIG_FILE"
  exit 1
fi

SLURM_SCRIPT="$DIR_MAIN/scripts/04_simulations/emulator/run_LSE_split_hpc_fir.slurm"

if [ ! -f "$SLURM_SCRIPT" ]; then
  echo "Slurm script does not exist:"
  echo "  $SLURM_SCRIPT"
  exit 1
fi

# ==============================================================================
# Workflow configuration
# ==============================================================================

CONFIG_VALUES="$(
  Rscript - "$DIR_MAIN" "$CONFIG_FILE" "$TIMESTEP" <<'RS'
args <- commandArgs(trailingOnly = TRUE)
source(file.path(args[1], "scripts/functions/common.R"))
experiment <- load_workflow_config(
  args[2], timestep = args[3]
)
cat(
  experiment$timestep,
  experiment$zDecision,
  experiment$nRefinementSteps
)
RS
)"

read -r TIMESTEP CONFIG_ZDECISION CONFIG_NREFINE <<< "$CONFIG_VALUES"

ZDECISION="${ZDECISION_OVERRIDE:-$CONFIG_ZDECISION}"
NREFINE="${NREFINE:-$CONFIG_NREFINE}"

EXPERIMENT_ROOT="$DIR_MAIN/experiments/$TIMESTEP/$EXPERIMENT"

if [ ! -d "$EXPERIMENT_ROOT" ]; then
  echo "Experiment directory does not exist:"
  echo "  $EXPERIMENT_ROOT"
  exit 1
fi

echo "============================================================"
echo "Submitting LSE experiment"
echo "============================================================"
echo "Repository   : $DIR_MAIN"
echo "Timestep     : $TIMESTEP"
echo "Experiment   : $EXPERIMENT"
echo "zDecision    : $ZDECISION"
echo "Refinements  : $NREFINE"
echo "============================================================"


# ==============================================================================
# Discover splits
# ==============================================================================

splits=()

for split in "$EXPERIMENT_ROOT"/*; do
  if [ -d "$split" ] && [ -f "$split/train_basins.txt" ] && [ -f "$split/test_basins.txt" ]; then
    splits+=("$split")
  fi
done

if [ "${#splits[@]}" -eq 0 ]; then
  echo "No valid experiment splits found under:"
  echo "  $EXPERIMENT_ROOT"
  exit 1
fi

echo "Splits found: ${#splits[@]}"
echo


# ==============================================================================
# Submit one Slurm job per split
# ==============================================================================

echo "Validating experiment splits before submission..."

VALIDATOR="$DIR_MAIN/scripts/03_experiments/02_validate_experiment_splits.R"

if [ ! -f "$VALIDATOR" ]; then
  echo "Experiment split validator does not exist:"
  echo "  $VALIDATOR"
  exit 1
fi

Rscript "$VALIDATOR" "$EXPERIMENT" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP"

echo "Experiment splits validated successfully."
echo

for EXPERIMENT_DIR in "${splits[@]}"; do

  split_name="$(basename "$EXPERIMENT_DIR")"

  echo "Submitting $split_name"

  job_id=$(
    sbatch \
      --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE",EXPERIMENT_DIR="$EXPERIMENT_DIR",NREFINE="$NREFINE" \
      "$SLURM_SCRIPT" --timestep "$TIMESTEP" --zdecision "$ZDECISION" \
      | awk '{print $4}'
  )

  echo "  Job ID: $job_id"
done

echo
echo "All ${#splits[@]} split(s) submitted."