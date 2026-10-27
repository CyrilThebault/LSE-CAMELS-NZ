#!/bin/bash
#SBATCH --job-name=localcalib
#SBATCH --account=rrg-mclark
#SBATCH --output=logs/local_calibration/%x_%A_%a.log
#SBATCH --error=logs/local_calibration/%x_%A_%a.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4000M
#SBATCH --time=1-00:00:00
#SBATCH --mail-type=FAIL

set -euo pipefail

# FIR software environment
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

# Verify that the input files match those validated at submission.
# Fail closed if the submission fingerprints were not provided.
BASIN_SHA256="${BASIN_SHA256:?Missing BASIN_SHA256 from submission}"
CONFIG_SHA256="${CONFIG_SHA256:?Missing CONFIG_SHA256 from submission}"

verify_sha256() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local output actual

  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing $label file: $file" >&2
    return 1
  fi

  output="$(sha256sum "$file")" || {
    echo "ERROR: cannot compute SHA-256 for $label" >&2
    return 1
  }

  actual="${output%% *}"

  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: SHA-256 mismatch for $label: $file" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    return 1
  fi
}

verify_sha256 "$BASIN_FILE" "$BASIN_SHA256" "BASIN_FILE"
verify_sha256 "$CONFIG_FILE" "$CONFIG_SHA256" "CONFIG_FILE"

# Use the canonical R basin-list reader.
# Slurm array indices refer to positions in the validated list.
BASIN_IDS="$(
  Rscript --vanilla - "$DIR_MAIN" "$BASIN_FILE" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/basins.R"))

basins <- read_basin_ids(args[2])
cat(paste(basins, collapse = "\n"))
RS
)" || {
  echo "Failed to validate basin list: $BASIN_FILE" >&2
  exit 1
}

mapfile -t BASINS <<< "$BASIN_IDS"

INDEX="${SLURM_ARRAY_TASK_ID:?Submit with --array}"

if (( INDEX < 1 || INDEX > ${#BASINS[@]} )); then
  echo "Invalid array index: $INDEX" >&2
  exit 1
fi

BASIN_ID="${BASINS[$((INDEX - 1))]}"

# Read zDecision from the experiment configuration.
ZDECISION="$(
  Rscript -e '
    args <- commandArgs(trailingOnly = TRUE)
    source(file.path(args[2], "scripts/functions/common.R"))
    experiment <- load_workflow_config(args[1])
    cat(experiment$zDecision)
  ' "$CONFIG_FILE" "$DIR_MAIN"
)"



echo "===== SCE ARRAY TASK ====="
echo "Array task: $INDEX / ${#BASINS[@]}"
echo "Basin: $BASIN_ID"
echo "Configuration: $CONFIG_FILE"
echo "Basin file: $BASIN_FILE"
echo "Basin SHA256: $BASIN_SHA256"
echo "Config SHA256: $CONFIG_SHA256"

# Validate the selected basin's archive with the common R helper.
# This check also runs in DRY_RUN mode.
ARCHIVE_RESULT="$(
  Rscript --vanilla - \
    "$DIR_MAIN" "$EXPERIMENT_DIR" "$BASIN_ID" "$ZDECISION" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/local_calibration.R"))

archive <- local_calibration_archive_status(
  experiment_dir = args[2],
  basinID = args[3],
  zDecision = args[4]
)

reason <- gsub("[\t\r\n]", " ", archive$reason)
cat(archive$status, reason, sep = "\t")
RS
)" || {
  echo "ERROR: failed to inspect calibration archive for $BASIN_ID" >&2
  exit 1
}

IFS=$'\t' read -r ARCHIVE_STATUS ARCHIVE_REASON <<< "$ARCHIVE_RESULT"

case "$ARCHIVE_STATUS" in
  complete|absent)
    echo "Archive status: $ARCHIVE_STATUS ($ARCHIVE_REASON)"
    ;;
  incomplete)
    echo "ERROR: incomplete calibration archive for $BASIN_ID: $ARCHIVE_REASON" >&2
    exit 1
    ;;
  *)
    echo "ERROR: unknown archive status for $BASIN_ID: $ARCHIVE_STATUS" >&2
    exit 1
    ;;
esac

# Dry run validates the array mapping and archive without starting FUSE.
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN -- basin selected, no calibration started"
  exit 0
fi

if [[ "$ARCHIVE_STATUS" == "complete" ]]; then
  echo "SKIP: calibration already archived"
  exit 0
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
