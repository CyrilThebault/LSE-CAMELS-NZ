#!/usr/bin/env bash

set -euo pipefail

usage="Usage: bash submit_iter0_hpc_fir.sh <DIR_MAIN> <CONFIG_FILE> --timestep <daily|hourly> [--zdecision <value>]"

if [[ "$#" -ne 4 && "$#" -ne 6 ]]; then
  echo "$usage" >&2
  exit 2
fi

if [[ "${3:-}" != "--timestep" ]]; then
  echo "$usage" >&2
  exit 2
fi

if [[ "$#" -eq 6 ]]; then
  if [[ "$5" != "--zdecision" || -z "$6" ]]; then
    echo "$usage" >&2
    exit 2
  fi
fi

REQUESTED_ZDECISION="${6:-}"

DIR_MAIN="$(cd "$1" && pwd -P)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"

TIMESTEP="$4"

case "$TIMESTEP" in
  daily|hourly)
    ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac


BASIN_FILE="$DIR_MAIN/config/basins.txt"
SLURM_SCRIPT="$DIR_MAIN/scripts/02_iter0/run_iter0_hpc_fir.slurm"

for required_file in "$CONFIG_FILE" "$BASIN_FILE" "$SLURM_SCRIPT"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done

# FIR software environment.
module --force purge
module load StdEnv/2023
module load r/4.4.0

# Use the canonical basin-list reader shared with the R workflow.
# Slurm array indices refer to positions in the validated basin list.
NBASINS="$(
  Rscript --vanilla - "$DIR_MAIN" "$BASIN_FILE" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/basins.R"))

basins <- read_basin_ids(args[2])
cat(length(basins))
RS
)"

DECISIONS_FILE="$(mktemp "${TMPDIR:-/tmp}/lse_iter0_decisions.XXXXXXXX")"
trap 'rm -f "$DECISIONS_FILE"' EXIT

Rscript --vanilla - "$DIR_MAIN" "$CONFIG_FILE" "$REQUESTED_ZDECISION" "$DECISIONS_FILE" "$TIMESTEP" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/common.R"))
if (
  length(args) != 5L ||
  !(args[5] %in% c("daily", "hourly"))
) {
  stop("Invalid explicit timestep passed to iter0 decision selector")
}

experiment <- load_workflow_config(
  args[2],
  timestep = args[5]
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
  stop("zDecision values cannot contain commas, equals signs or newlines")
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

  decisions <- requested
}

writeLines(decisions, args[4])
RS

# Slurm log paths in the batch script are relative to submission directory.
mkdir -p "$DIR_MAIN/logs/iter0"
cd "$DIR_MAIN"

echo "========================================"
echo "Submitting iter0 on FIR"
echo "Basins       : $NBASINS"
echo "Configuration: $CONFIG_FILE"
echo "Decisions    : $(paste -sd ',' "$DECISIONS_FILE")"
echo "========================================"

while IFS= read -r DECISION; do
  echo "Submitting zDecision=$DECISION"

  JOB_ID="$(
    sbatch \
      --parsable \
      --array="1-$NBASINS" \
      "$SLURM_SCRIPT" \
      "$DIR_MAIN" "$CONFIG_FILE" "$DECISION" \
      --timestep "$TIMESTEP"
  )"

  echo "Submitted job $JOB_ID for zDecision=$DECISION"
done < "$DECISIONS_FILE"
