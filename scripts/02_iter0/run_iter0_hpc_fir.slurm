#!/bin/bash
#SBATCH --job-name=iter0
#SBATCH --account=rrg-mclark
#SBATCH --output=logs/iter0/%x_%A_%a.log
#SBATCH --error=logs/iter0/%x_%A_%a.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=01-00:00:00
#SBATCH --mail-type=FAIL


set -euo pipefail

# ==============================================================================
# FIR software environment
# ==============================================================================

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

# Each basin is run independently with GNU Parallel, so keep numerical libraries
# single-threaded to avoid oversubscribing the allocated CPUs.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID:?This script must be submitted as a Slurm job array}"

# ==============================================================================
# Workflow configuration
# ==============================================================================

if [[ "$#" -ne 5 || "${4:-}" != "--timestep" ]]; then
  echo "Usage: sbatch --array=1-N $(basename "$0") <DIR_MAIN> <CONFIG_FILE> <ZDECISION> --timestep <daily|hourly>" >&2
  exit 2
fi

DIR_MAIN="$(cd "$1" && pwd -P)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
ZDECISION_REQUESTED="$3"
TIMESTEP="$5"

case "$TIMESTEP" in
  daily|hourly)
    ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing configuration: $CONFIG_FILE" >&2
  exit 2
fi


ZDECISION="$(
  Rscript --vanilla - "$DIR_MAIN" "$CONFIG_FILE" "$ZDECISION_REQUESTED" "$TIMESTEP" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/common.R"))
if (
  length(args) != 4L ||
  !(args[4] %in% c("daily", "hourly"))
) {
  stop("Invalid explicit timestep passed to iter0 decision selector")
}

experiment <- load_workflow_config(
  args[2],
  timestep = args[4]
)

decisions <- as.character(experiment$zDecision)

if (
  !length(decisions) ||
  anyNA(decisions) ||
  any(!nzchar(trimws(decisions))) ||
  anyDuplicated(decisions)
) {
  stop("Invalid experiment$zDecision configuration")
}

if (any(grepl("[,=\r\n]", decisions))) {
  stop("Invalid characters in configured zDecision")
}

requested <- args[3]

if (nzchar(requested)) {
  if (!requested %in% decisions) {
    stop(
      "ZDECISION ", requested,
      " is not allowed. Configured: ",
      paste(decisions, collapse = ", ")
    )
  }

  cat(requested)

} else {
  if (length(decisions) != 1L) {
    stop(
      "Multiple zDecisions are configured. ",
      "Use the iter0 submitter or provide ZDECISION explicitly."
    )
  }

  cat(decisions)
}
RS
)"

BASIN_FILE="$DIR_MAIN/config/basins.txt"

if [[ ! -f "$BASIN_FILE" ]]; then
  echo "Missing basin file: $BASIN_FILE" >&2
  exit 1
fi

# ==============================================================================
# Basin selection
# ==============================================================================

BASIN_ID="$(
  Rscript --vanilla - "$DIR_MAIN" "$BASIN_FILE" "$ARRAY_TASK_ID" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/basins.R"))

basins <- read_basin_ids(args[2])
index_text <- args[3]

if (!grepl("^[1-9][0-9]*$", index_text)) {
  stop("Invalid Slurm array task ID: ", index_text)
}

index <- suppressWarnings(as.integer(index_text))

if (is.na(index) || index > length(basins)) {
  stop(
    "Slurm array task ", index_text,
    " is outside the basin list (1-", length(basins), ")"
  )
}

cat(basins[index])
RS
)"

echo "Array task: ${ARRAY_TASK_ID}"
echo "Running iter0 for basin: ${BASIN_ID}"

# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_ROOT="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}"
TMP_BASE="$TMP_ROOT/lse_iter0_${SLURM_ARRAY_JOB_ID}_${ARRAY_TASK_ID}"
mkdir -p "$TMP_BASE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" "$BASIN_ID" "$ZDECISION" "$TMP_BASE" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP"
