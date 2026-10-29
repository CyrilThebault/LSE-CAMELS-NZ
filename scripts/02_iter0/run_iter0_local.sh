# Stop on errors, unset variables and failed commands in pipelines.
set -euo pipefail

# Each basin is run independently with GNU Parallel, so keep numerical libraries
# single-threaded to avoid oversubscribing the allocated CPUs.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1


# ==============================================================================
# Workflow configuration
# ==============================================================================

usage="Usage: bash run_iter0_local.sh <DIR_MAIN> <CONFIG_FILE> --timestep <daily|hourly> [--zdecision <value>]"

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

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing configuration: $CONFIG_FILE" >&2
  exit 2
fi


NCORES="${NCORES:-4}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_BASE="$(mktemp -d "${TMP_ROOT%/}/lse_iter0.XXXXXXXX")"

echo "Iter0 temporary workspace: $TMP_BASE"

BASIN_FILE="$DIR_MAIN/config/basins.txt"
BASINS_FILE="$TMP_BASE/basins.txt"

Rscript --vanilla - "$DIR_MAIN" "$BASIN_FILE" "$BASINS_FILE" <<'RS'
args <- commandArgs(trailingOnly = TRUE)

source(file.path(args[1], "scripts/functions/basins.R"))

basins <- read_basin_ids(args[2])
writeLines(basins, args[3])

cat("Selected basins:", length(basins), "\n")
RS

DECISIONS_FILE="$TMP_BASE/zdecisions.txt"

Rscript --vanilla -e '
  args <- commandArgs(trailingOnly = TRUE)

  source(file.path(args[4], "scripts/functions/common.R"))

  if (
    length(args) != 5L ||
    !(args[5] %in% c("daily", "hourly"))
  ) {
    stop("Invalid explicit timestep passed to iter0 decision selector")
  }

  experiment <- load_workflow_config(
    args[1],
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
    stop("Invalid characters in configured zDecision")
  }

  requested <- args[2]

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

  writeLines(decisions, args[3])
  cat("Selected zDecisions:", paste(decisions, collapse = ", "), "\n")
' "$CONFIG_FILE" "$REQUESTED_ZDECISION" "$DECISIONS_FILE" "$DIR_MAIN" "$TIMESTEP"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag \
  Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" \
  {1} {2} "$TMP_BASE/{2}/{1}" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP" \
  :::: "$BASINS_FILE" \
  :::: "$DECISIONS_FILE"
