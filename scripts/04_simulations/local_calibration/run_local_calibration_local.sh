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
seen=" "

while IFS= read -r basinID || [[ -n "$basinID" ]]; do

  # Accept blank lines and comments.
  [[ -z "$basinID" || "$basinID" == \#* ]] && continue

  [[ "$basinID" =~ ^[0-9]+$ ]] || {
    echo "Invalid basin ID: $basinID" >&2
    exit 1
  }

  # Prevent duplicate runs of the same basin.
  if [[ "$seen" == *" $basinID "* ]]; then
    echo "Duplicate basin ID: $basinID" >&2
    exit 1
  fi
  seen="${seen}${basinID} "

  raw_dir="$EXPERIMENT_DIR/outputs/zDecision_${ZDECISION}/${basinID}/sce"
  hydro_dir="$EXPERIMENT_DIR/hydrographs/zDecision_${ZDECISION}/${basinID}/sce"

  forcing="$DIR_MAIN/data/forcings/$TIMESTEP/$basinID/${basinID}_input.nc"

  prefix="${basinID}_${ZDECISION}__"

  # A completed calibration must contain its essential outputs.
  if [[ -f "$hydro_dir/qSim_selected.rds" &&
        -f "$hydro_dir/metadata.rds" &&
        -f "$raw_dir/${prefix}para_sce.nc" &&
        -f "$raw_dir/${prefix}para_opt.nc" &&
        -f "$raw_dir/${prefix}runs_opt.nc" &&
        -f "$raw_dir/${prefix}sce_output.txt" &&
        -f "$raw_dir/sce_console.log" &&
        -f "$raw_dir/opt_console.log" &&
        -f "$raw_dir/fuse_control.toml" ]]; then

    completed+=("$basinID")
    continue
  fi

  # Never interpret partial archives as a completed run.
  if [[ -e "$raw_dir" || -e "$hydro_dir" ]]; then
    echo "Incomplete archive for basin $basinID:" >&2
    echo "$raw_dir" >&2
    echo "$hydro_dir" >&2
    exit 1
  fi

  if [[ ! -f "$forcing" ]]; then
    missing+=("$basinID")
    continue
  fi

  pending+=("$basinID")

done < "$BASIN_FILE"

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
