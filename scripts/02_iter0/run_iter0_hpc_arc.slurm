#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4000
#SBATCH --time=12:00:00
#SBATCH -J lse_iter0
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/iter0/%x_%A_%a.log
#SBATCH --error=logs/iter0/%x_%A_%a.log

# Stop on errors, unset variables and failed commands in pipelines.
set -euo pipefail

# Load the software stack required by FUSE and the R workflow.
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

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"

ZDECISION="$(
  Rscript --vanilla - "$DIR_MAIN" "$CONFIG_FILE" "${ZDECISION:-}" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/common.R"))
experiment <- load_workflow_config(args[2])

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

TMP_BASE="${TMPDIR:-/tmp}/lse_iter0_${SLURM_ARRAY_JOB_ID}_${ARRAY_TASK_ID}"
mkdir -p "$TMP_BASE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" "$BASIN_ID" "$ZDECISION" "$TMP_BASE" "$CONFIG_FILE" "$DIR_MAIN"
