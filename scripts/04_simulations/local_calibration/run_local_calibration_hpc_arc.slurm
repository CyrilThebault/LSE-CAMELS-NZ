#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4000M
#SBATCH --time=1-00:00:00
#SBATCH --job-name=localcalib
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/local_calibration/%x_%A_%a.log
#SBATCH --error=logs/local_calibration/%x_%A_%a.log

set -euo pipefail

# ARC software environment
. /work/comphyd_lab/local/modules/spack/2024v5/lmod-init-bash

module purge
module unuse "$MODULEPATH"
module use /work/comphyd_lab/local/modules/spack/2024v5/modules/linux-rocky8-x86_64/Core/

module load gcc/14.2.0
module load cmake/3.30.2
module load hdf5/1.14.3
module load netcdf-c/4.9.2
module load netcdf-fortran/4.6.1
module load r/4.4.1

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

# Configuration
DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:?Set EXPERIMENT_DIR}"
BASIN_FILE="${BASIN_FILE:-$DIR_MAIN/config/basins.txt}"

[[ -f "$BASIN_FILE" ]] || {
  echo "Missing basin file: $BASIN_FILE" >&2
  exit 1
}

# One array index corresponds to one line of basin IDs.
# Empty lines and comment lines are ignored.
mapfile -t BASINS < <(
  awk 'NF && $1 !~ /^#/ {print $1}' "$BASIN_FILE"
)

INDEX="${SLURM_ARRAY_TASK_ID:?Submit with --array}"

if (( INDEX < 1 || INDEX > ${#BASINS[@]} )); then
  echo "Invalid array index: $INDEX" >&2
  exit 1
fi

BASIN_ID="${BASINS[$((INDEX - 1))]}"

[[ "$BASIN_ID" =~ ^[0-9]+$ ]] || {
  echo "Invalid basin ID: $BASIN_ID" >&2
  exit 1
}

# Read zDecision from the experiment configuration.
ZDECISION="$(
  Rscript -e '
    args <- commandArgs(trailingOnly = TRUE)
    source(file.path(args[2], "scripts/functions/common.R"))
    experiment <- load_workflow_config(args[1])
    cat(experiment$zDecision)
  ' "$CONFIG_FILE" "$DIR_MAIN"
)"

RAW_DIR="$EXPERIMENT_DIR/outputs/zDecision_${ZDECISION}/${BASIN_ID}/sce"
HYDRO_DIR="$EXPERIMENT_DIR/hydrographs/zDecision_${ZDECISION}/${BASIN_ID}/sce"

PREFIX="${BASIN_ID}_${ZDECISION}__"

echo "===== SCE ARRAY TASK ====="
echo "Array task: $INDEX / ${#BASINS[@]}"
echo "Basin: $BASIN_ID"
echo "Configuration: $CONFIG_FILE"
echo "Basin file: $BASIN_FILE"
sha256sum "$BASIN_FILE"

# Allow safe validation of the Slurm array mapping.
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN -- basin selected, no calibration started"
  exit 0
fi

# Skip completed calibrations.
if [[ -f "$HYDRO_DIR/qSim_selected.rds" &&
      -f "$HYDRO_DIR/metadata.rds" &&
      -f "$RAW_DIR/${PREFIX}para_sce.nc" &&
      -f "$RAW_DIR/${PREFIX}para_opt.nc" &&
      -f "$RAW_DIR/${PREFIX}runs_opt.nc" &&
      -f "$RAW_DIR/${PREFIX}sce_output.txt" &&
      -f "$RAW_DIR/sce_console.log" &&
      -f "$RAW_DIR/opt_console.log" &&
      -f "$RAW_DIR/fuse_control.toml" ]]; then
  echo "SKIP: calibration already archived"
  exit 0
fi

# Never overwrite incomplete results.
if [[ -e "$RAW_DIR" || -e "$HYDRO_DIR" ]]; then
  echo "ERROR: incomplete calibration archive for $BASIN_ID" >&2
  exit 1
fi

# Unique scratch directory for this array task.
TMP_ROOT="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
WORK_ROOT="$TMP_ROOT/lse_sce_${SLURM_ARRAY_JOB_ID}_${INDEX}"
WORK="$WORK_ROOT/fuse_workspace"

mkdir -p "$WORK_ROOT"

Rscript \
  "$DIR_MAIN/scripts/04_simulations/local_calibration/01_run_local_calibration.R" \
  "$BASIN_ID" \
  "$EXPERIMENT_DIR" \
  run \
  "$WORK" \
  "$CONFIG_FILE" \
  "$DIR_MAIN"

echo "SCE ARRAY TASK COMPLETE: $BASIN_ID"
