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

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"

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

  env <- new.env(parent = globalenv())
  sys.source(args[1], envir = env)

  decisions <- as.character(env$experiment$zDecision)

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
' "$CONFIG_FILE" "${ZDECISION:-}" "$DECISIONS_FILE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag \
  Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" \
  {1} {2} "$TMP_BASE/{2}/{1}" "$CONFIG_FILE" "$DIR_MAIN" \
  :::: "$BASINS_FILE" \
  :::: "$DECISIONS_FILE"
