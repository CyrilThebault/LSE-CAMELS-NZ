#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 || "$3" != "--timestep" ]]; then
  echo "Usage: bash submit_local_calibration_hpc_arc.sh <DIR_MAIN> <CONFIG_FILE> --timestep <daily|hourly>" >&2
  exit 2
fi

TIMESTEP="$4"

case "$TIMESTEP" in
  daily|hourly) ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac

DIR_MAIN="$(cd "$1" && pwd -P)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"

# Resolution is validated by the required --timestep argument.


BASIN_FILE="${BASIN_FILE:-$DIR_MAIN/config/basins.txt}"
SLURM_SCRIPT="$DIR_MAIN/scripts/04_simulations/local_calibration/run_local_calibration_hpc_arc.slurm"
DRY_RUN="${DRY_RUN:-0}"

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || {
  echo "DRY_RUN must be 0 or 1" >&2
  exit 1
}

for required_file in "$CONFIG_FILE" "$BASIN_FILE" "$SLURM_SCRIPT"; do
  [[ -f "$required_file" ]] || {
    echo "Missing required file: $required_file" >&2
    exit 1
  }
done

BASIN_FILE="$(cd "$(dirname "$BASIN_FILE")" && pwd -P)/$(basename "$BASIN_FILE")"

# ARC software environment is needed only for real submission.
# DRY_RUN can therefore be tested locally.
if [[ "$DRY_RUN" == 0 ]]; then
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
fi

# Capture the input file fingerprints before configuration validation.
# Support SHA-256 on HPC Linux and macOS for local dry-run tests.
file_sha256() {
  local result

  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum "$1")" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    result="$(shasum -a 256 "$1")" || return 1
  else
    echo "No SHA-256 command available" >&2
    return 1
  fi

  printf '%s\n' "${result%% *}"
}

BASIN_SHA256="$(file_sha256 "$BASIN_FILE")"
CONFIG_SHA256="$(file_sha256 "$CONFIG_FILE")"

# The canonical basin list and experiment configuration
# determine the Slurm array size and scientific settings.
SETTINGS="$(
  Rscript --vanilla - "$DIR_MAIN" "$CONFIG_FILE" "$BASIN_FILE" "$TIMESTEP" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/common.R"))
source(file.path(args[1], "scripts/functions/basins.R"))

experiment <- load_workflow_config(
  args[2], timestep = args[4]
)
basins <- read_basin_ids(args[3])

timestep <- experiment$timestep
zDecision <- as.character(experiment$zDecision)

if (length(timestep) != 1L ||
    is.na(timestep) ||
    !timestep %in% c("daily", "hourly")) {
  stop("Invalid experiment timestep")
}

if (length(zDecision) != 1L ||
    is.na(zDecision) ||
    !nzchar(zDecision) ||
    grepl("[[:space:],=/]", zDecision)) {
  stop("Expected one valid zDecision in experiment configuration")
}

cat(length(basins), timestep, zDecision, sep = "\t")
RS
)" || {
  echo "Failed to validate basin list or experiment configuration" >&2
  exit 1
}

read -r NBASINS TIMESTEP ZDECISION <<< "$SETTINGS"

# Refuse submission if an input changed while it was being validated.
if [[ "$(file_sha256 "$BASIN_FILE")" != "$BASIN_SHA256" ||
      "$(file_sha256 "$CONFIG_FILE")" != "$CONFIG_SHA256" ]]; then
  echo "Input files changed during submission validation" >&2
  exit 1
fi

EXPERIMENT_DIR="${EXPERIMENT_DIR:-$DIR_MAIN/experiments/$TIMESTEP/localcalib/all_basins}"

[[ "$EXPERIMENT_DIR" == /* ]] || {
  echo "EXPERIMENT_DIR must be an absolute path" >&2
  exit 1
}

echo
echo "===== LOCAL CALIBRATION ARC SUBMISSION ====="
echo "Repository:     $DIR_MAIN"
echo "Configuration:  $CONFIG_FILE"
echo "Timestep:       $TIMESTEP"
echo "zDecision:      $ZDECISION"
echo "Basin file:     $BASIN_FILE"
echo "Basin SHA256:   $BASIN_SHA256"
echo "Config SHA256:  $CONFIG_SHA256"
echo "Basins:         $NBASINS"
echo "Slurm array:    1-$NBASINS"
echo "Experiment:     $EXPERIMENT_DIR"
echo "Slurm script:   $SLURM_SCRIPT"
echo "Dry run:        $DRY_RUN"

if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "DRY RUN COMPLETE -- NO SLURM JOB SUBMITTED"
  exit 0
fi

# Slurm log paths are relative to the submission directory.
mkdir -p "$DIR_MAIN/logs/local_calibration"
cd "$DIR_MAIN"

JOB_ID="$(
  sbatch \
    --parsable \
    --array="1-$NBASINS" \
    --export="ALL,DIR_MAIN=$DIR_MAIN,CONFIG_FILE=$CONFIG_FILE,EXPERIMENT_DIR=$EXPERIMENT_DIR,BASIN_FILE=$BASIN_FILE,BASIN_SHA256=$BASIN_SHA256,CONFIG_SHA256=$CONFIG_SHA256" \
    "$SLURM_SCRIPT" --timestep "$TIMESTEP"
)"

echo
echo "Submitted local calibration ARC job: $JOB_ID"
