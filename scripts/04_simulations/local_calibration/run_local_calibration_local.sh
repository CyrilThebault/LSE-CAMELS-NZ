#!/usr/bin/env bash

set -euo pipefail

# Each FUSE calibration runs on one CPU.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

# ==================================================
# Configuration
# ==================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:?Set EXPERIMENT_DIR}"

BASIN_FILE="${BASIN_FILE:-$DIR_MAIN/config/basins.txt}"
NCORES="${NCORES:-${SLURM_CPUS_PER_TASK:-4}}"
DRY_RUN="${DRY_RUN:-0}"

[[ -f "$BASIN_FILE" ]] || {
  echo "Missing basin file: $BASIN_FILE" >&2
  exit 1
}

[[ "$NCORES" =~ ^[1-9][0-9]*$ ]] || {
  echo "NCORES must be a positive integer" >&2
  exit 1
}

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || {
  echo "DRY_RUN must be 0 or 1" >&2
  exit 1
}

# Read the experiment configuration using the existing R helper.
settings="$(
  Rscript -e '
    args <- commandArgs(trailingOnly = TRUE)
    source(file.path(args[2], "scripts/functions/common.R"))
    experiment <- load_workflow_config(args[1])
    cat(experiment$timestep, experiment$zDecision)
  ' "$CONFIG_FILE" "$DIR_MAIN"
)"

read -r TIMESTEP ZDECISION <<< "$settings"

[[ "$TIMESTEP" == daily || "$TIMESTEP" == hourly ]] || {
  echo "Invalid experiment timestep" >&2
  exit 1
}

RUNNER="$DIR_MAIN/scripts/04_simulations/local_calibration/01_run_local_calibration.R"

TMP_BASE="${TMP_BASE:-${TMPDIR:-/tmp}/lse_localcalib_${SLURM_JOB_ID:-$$}}"

echo
echo "===== LOCAL CALIBRATION CAMPAIGN ====="
echo "Experiment: $EXPERIMENT_DIR"
echo "Configuration: $CONFIG_FILE"
echo "Basins: $BASIN_FILE"
echo "Timestep: $TIMESTEP"
echo "zDecision: $ZDECISION"
echo "Parallel jobs: $NCORES"
echo "Dry run: $DRY_RUN"

echo
echo "===== BASIN FILE CHECKSUM ====="

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$BASIN_FILE"
else
  shasum -a 256 "$BASIN_FILE"
fi

# ==================================================
# Inspect all requested basins before launching
# ==================================================

pending=()
missing=()
completed=()

# Read and validate the canonical basin list, then inspect all archives.
# One R process handles the entire campaign.
BASIN_PREFLIGHT="$(
  Rscript --vanilla - \
    "$DIR_MAIN" "$BASIN_FILE" "$EXPERIMENT_DIR" "$ZDECISION" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/basins.R"))
source(file.path(args[1], "scripts/functions/local_calibration.R"))

basins <- read_basin_ids(args[2])

for (basin in basins) {
  archive <- local_calibration_archive_status(
    experiment_dir = args[3],
    basinID = basin,
    zDecision = args[4]
  )

  reason <- gsub("[\t\r\n]", " ", archive$reason)

  cat(basin, archive$status, reason, sep = "\t")
  cat("\n")
}
RS
)" || {
  echo "Failed to validate basin list or calibration archives" >&2
  exit 1
}

while IFS=$'\t' read -r basinID archive_status archive_reason ||
      [[ -n "$basinID" ]]; do


  forcing="$DIR_MAIN/data/forcings/$TIMESTEP/$basinID/${basinID}_input.nc"


  # Archive status comes from the common R validator.
  case "$archive_status" in
    complete)
      completed+=("$basinID")
      continue
      ;;
    incomplete)
      echo "Incomplete archive for basin $basinID: $archive_reason" >&2
      exit 1
      ;;
    absent)
      ;;
    *)
      echo "Unknown archive status for basin $basinID: $archive_status" >&2
      exit 1
      ;;
  esac

  if [[ ! -f "$forcing" ]]; then
    missing+=("$basinID")
    continue
  fi

  pending+=("$basinID")

done <<< "$BASIN_PREFLIGHT"

total=$(( ${#completed[@]} + ${#pending[@]} + ${#missing[@]} ))

(( total > 0 )) || {
  echo "Basin list is empty" >&2
  exit 1
}

echo
echo "===== PREFLIGHT SUMMARY ====="
echo "Requested: $total"
echo "Already archived: ${#completed[@]}"
echo "Ready to run: ${#pending[@]}"
echo "Missing forcings: ${#missing[@]}"

if (( ${#missing[@]} > 0 )); then
  echo "Missing basin IDs: ${missing[*]}"
fi

if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "DRY RUN COMPLETE -- NO CALIBRATIONS STARTED"
  exit 0
fi

# Missing input files are an error, not an implicit exclusion.
if (( ${#missing[@]} > 0 )); then
  echo "Refusing to start: missing forcing files" >&2
  exit 1
fi

if (( ${#pending[@]} == 0 )); then
  echo "All requested calibrations are already archived"
  exit 0
fi

command -v parallel >/dev/null 2>&1 || {
  echo "GNU Parallel is required" >&2
  exit 1
}

mkdir -p "$TMP_BASE"

echo
echo "===== RUNNING SCE CALIBRATIONS ====="
echo "Temporary root: $TMP_BASE"

printf '%s\n' "${pending[@]}" |
  parallel \
    --jobs "$NCORES" \
    --line-buffer \
    --tag \
    --halt soon,fail=1 \
    Rscript "$RUNNER" \
      {} \
      "$EXPERIMENT_DIR" \
      run \
      "$TMP_BASE/{}/fuse_workspace" \
      "$CONFIG_FILE" \
      "$DIR_MAIN"

echo
echo "LOCAL CALIBRATION CAMPAIGN COMPLETE"
