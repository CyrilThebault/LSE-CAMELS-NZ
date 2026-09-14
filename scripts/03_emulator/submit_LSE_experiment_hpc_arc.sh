#!/bin/bash

set -euo pipefail

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

# ==============================================================================
# Submit all folds of one LSE experiment on ARC HPC
#
# Example:
#   bash submit_LSE_experiment_hpc_arc.sh \
#     /work/comphyd_lab/users/cyril.thebault/ESNZ/02_DATA/LSE-CAMELS-NZ \
#     kfold
#
# Optional environment overrides:
#   ZDECISION=126 NREFINE=2 bash submit_LSE_experiment_hpc_arc.sh <DIR_MAIN> kfold
# ==============================================================================

if [ "$#" -ne 2 ]; then
  echo "Usage: bash submit_LSE_experiment_hpc_arc.sh <DIR_MAIN> <experiment>"
  echo "Example: bash submit_LSE_experiment_hpc_arc.sh /path/to/LSE-CAMELS-NZ kfold"
  exit 1
fi

DIR_MAIN="$(cd "$1" && pwd)"
EXPERIMENT="$2"

SLURM_SCRIPT="$DIR_MAIN/scripts/03_emulator/run_LSE_split_hpc_arc.slurm"

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
# Discover folds
# ==============================================================================

folds=()

for fold in "$EXPERIMENT_ROOT"/*; do
  if [ -d "$fold" ] && [ -f "$fold/train_basins.txt" ] && [ -f "$fold/test_basins.txt" ]; then
    folds+=("$fold")
  fi
done

if [ "${#folds[@]}" -eq 0 ]; then
  echo "No valid experiment folds found under:"
  echo "  $EXPERIMENT_ROOT"
  exit 1
fi

echo "Folds found: ${#folds[@]}"
echo


# ==============================================================================
# Submit one Slurm job per fold
# ==============================================================================

for EXPERIMENT_DIR in "${folds[@]}"; do

  fold_name="$(basename "$EXPERIMENT_DIR")"

  echo "Submitting $fold_name"

  job_id=$(
    sbatch \
      --export=ALL,DIR_MAIN="$DIR_MAIN",EXPERIMENT_DIR="$EXPERIMENT_DIR",ZDECISION="$ZDECISION",NREFINE="$NREFINE" \
      "$SLURM_SCRIPT" \
      | awk '{print $4}'
  )

  echo "  Job ID: $job_id"
done

echo
echo "All ${#folds[@]} fold(s) submitted."