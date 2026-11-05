#!/usr/bin/env bash

# Run only the daily/hourly continuous comparison (stage 03).
# Stages 01 and 02 are launched separately and are not recomputed here.

set -euo pipefail

usage() {
  echo 'Usage: bash 03_compare_paired_daily_local.sh EVALUATIONS_RDS OUTDIR [--check] [--ncores=N]' >&2
  echo 'Required environment: DIR_MAIN and CONFIG_FILE (canonical config/experiment.R)' >&2
  echo 'Default NCORES: environment NCORES, then SLURM_CPUS_PER_TASK, then 4' >&2
  exit 2
}

(( $# >= 2 )) || usage
EVALUATIONS_RDS="$1"
OUTDIR="$2"
shift 2

CHECK=0
NCORES="${NCORES:-${SLURM_CPUS_PER_TASK:-4}}"
SEEN_CORES=0

while (( $# > 0 )); do
  case "$1" in
    --check)
      (( CHECK == 0 )) || usage
      CHECK=1
      ;;
    --ncores=*)
      (( SEEN_CORES == 0 )) || usage
      NCORES="${1#--ncores=}"
      SEEN_CORES=1
      ;;
    *) usage ;;
  esac
  shift
done

[[ "$NCORES" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid NCORES: $NCORES" >&2
  exit 2
}

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"

[[ -f "$CONFIG_FILE" && "$CONFIG_FILE" -ef "$DIR_MAIN/config/experiment.R" ]] || {
  echo 'CONFIG_FILE must reference the canonical config/experiment.R' >&2
  exit 1
}

[[ -f "$EVALUATIONS_RDS" ]] || {
  echo "Missing evaluations RDS: $EVALUATIONS_RDS" >&2
  exit 1
}

command -v Rscript >/dev/null 2>&1 || {
  echo 'Rscript is not available' >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARATOR="$SCRIPT_DIR/03_compare_paired_daily.R"
[[ -f "$COMPARATOR" ]] || {
  echo "Missing comparator: $COMPARATOR" >&2
  exit 1
}

# Each worker uses one CPU (no nested BLAS/OpenMP threads).
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1

ARGS=("$DIR_MAIN" "$EVALUATIONS_RDS" "$OUTDIR" "--ncores=$NCORES")
if (( CHECK == 1 )); then
  ARGS+=(--check)
fi

printf '===== PAIRED DAILY COMPARISON =====\n'
printf 'Evaluations: %s\n' "$EVALUATIONS_RDS"
printf 'Output: %s\n' "$OUTDIR"
printf 'Cores: %s\n' "$NCORES"
printf 'Mode: %s\n' "$([[ "$CHECK" == 1 ]] && echo CHECK || echo RUN)"

Rscript --vanilla "$COMPARATOR" "${ARGS[@]}"
