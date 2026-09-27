#!/bin/bash

set -euo pipefail



# ==============================================================================
# Submit all splits of one LSE experiment on FIR
#
# Example:
#   bash submit_LSE_experiment_hpc_fir.sh \
#     /home/thebault/ESNZ/02_DATA/LSE-CAMELS-NZ \
#     kfold
#
# Optional environment overrides:
#   ZDECISION=126 NREFINE=2 bash submit_LSE_experiment_hpc_fir.sh <DIR_MAIN> kfold
# ==============================================================================

module --force purge
module load StdEnv/2023
module load r/4.4.0

if [ "$#" -ne 2 ]; then
  echo "Usage: bash submit_LSE_experiment_hpc_fir.sh <DIR_MAIN> <experiment>"
  echo "Example: bash submit_LSE_experiment_hpc_fir.sh /path/to/LSE-CAMELS-NZ kfold"
  exit 1
fi

DIR_MAIN="$(cd "$1" && pwd)"
EXPERIMENT="$2"

SLURM_SCRIPT="$DIR_MAIN/scripts/03_emulator/run_LSE_split_hpc_fir.slurm"

if [ ! -f "$SLURM_SCRIPT" ]; then
  echo "Slurm script does not exist:"
  echo "  $SLURM_SCRIPT"
  exit 1
fi

# ==============================================================================
# Workflow configuration
# ==============================================================================

TIMESTEP="$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$timestep)")"

ZDECISION="${ZDECISION:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$zDecision)")}"
NREFINE="${NREFINE:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$nRefinementSteps)")}"

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

for EXPERIMENT_DIR in "${splits[@]}"; do

  split_name="$(basename "$EXPERIMENT_DIR")"

  echo "Submitting $split_name"

  job_id=$(
    sbatch \
      --export=ALL,DIR_MAIN="$DIR_MAIN",EXPERIMENT_DIR="$EXPERIMENT_DIR",ZDECISION="$ZDECISION",NREFINE="$NREFINE" \
      "$SLURM_SCRIPT" \
      | awk '{print $4}'
  )

  echo "  Job ID: $job_id"
done

echo
echo "All ${#splits[@]} split(s) submitted."