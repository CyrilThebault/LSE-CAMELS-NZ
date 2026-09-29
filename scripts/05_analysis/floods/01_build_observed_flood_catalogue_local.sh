#!/usr/bin/env bash

set -euo pipefail

# Basin-level parallelism is handled by R; keep each worker single-threaded.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_THREAD_LIMIT=1


# ==============================================================================
# Workflow configuration
# ==============================================================================

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN to the LSE-CAMELS-NZ repository root}"
NCORES="${NCORES:-4}"


# ==============================================================================
# Build canonical observed flood catalogue
# ==============================================================================

Rscript \
  "$DIR_MAIN/scripts/05_analysis/floods/01_build_observed_flood_catalogue.R" \
  "$DIR_MAIN" \
  "$NCORES"
