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

ZDECISION="${ZDECISION:-$(Rscript -e "source('${DIR_MAIN}/config/experiment.R'); cat(experiment\$zDecision)")}"

NCORES="${NCORES:-4}"


# ==============================================================================
# Temporary workspace
# ==============================================================================

TMP_BASE="${TMPDIR:-/tmp}/lse_iter0"
mkdir -p "$TMP_BASE"

# ==============================================================================
# Initial FUSE ensemble
#
# Each basin gets its own temporary FUSE workspace to avoid collisions between
# concurrent model runs.
# ==============================================================================

parallel -j "$NCORES" --line-buffer --tag Rscript "$DIR_MAIN/scripts/02_iter0/01_run_iter0.R" {} "$ZDECISION" "$TMP_BASE/{}" "$DIR_MAIN" :::: "$DIR_MAIN/config/basins.txt"
