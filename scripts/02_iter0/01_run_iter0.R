#!/usr/bin/env Rscript

# ==============================================================================
# Run the initial FUSE parameter ensemble for one basin
#
# The initial ensemble is sampled with Latin Hypercube Sampling over the active
# parameter space of the selected FUSE configuration. Each parameter set is run
# with FUSE and evaluated over the calibration and evaluation periods.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 4L) {
  stop("Usage: Rscript 01_run_iter0.R <basinID> <zDecision> <work_dir> <dirMain>")
}

basinID <- as.character(args[1])
zDecision <- as.character(args[2])
work_dir <- args[3]
dirMain <- normalizePath(args[4], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain, experiment)

suppressPackageStartupMessages({
  library(ncdf4)
  library(lhs)
})


# ==============================================================================
# FUSE configuration and workspace
# ==============================================================================

meta <- load_rdata_single(file.path(paths$useful, "fuse_settings_files.RData"))
info <- get_parameter_info(meta, zDecision)

prepare_fuse_workspace(dirMain, work_dir, basinID, zDecision, experiment)

qObs <- read_qobs(file.path(work_dir, "input", paste0(basinID, "_input.nc")), experiment)
periods <- metric_periods_from_config(experiment)


# ==============================================================================
# Initial parameter ensemble
# ==============================================================================

# The basin ID is included in the seed so that the initial parameter ensemble is
# reproducible but differs between catchments.
set.seed(experiment$seed + sum(utf8ToInt(basinID)))

lhsParams <- lhs::randomLHS(experiment$nIter0, length(info$rows))
colnames(lhsParams) <- info$names

KGEc <- KGEe <- rep(NA_real_, experiment$nIter0)
metrics <- vector("list", experiment$nIter0)


# ==============================================================================
# Run FUSE for each initial parameter set
# ==============================================================================

for (i in seq_len(experiment$nIter0)) {
  
  t0 <- Sys.time()
  
  res <- run_fuse(
    lhsParams[i, ],
    basinID,
    zDecision,
    meta,
    work_dir,
    qObs,
    periods,
    experiment
  )
  
  if (isTRUE(res$ok)) {
    metrics[[i]] <- res$qMetrics
    KGEc[i] <- res$qMetrics$KGE.2009[res$qMetrics$period == "calibration"]
    KGEe[i] <- res$qMetrics$KGE.2009[res$qMetrics$period == "evaluation"]
  }
  
  elapsed <- round(difftime(Sys.time(), t0, units = "secs"), 2)
  
  message(
    "iter0 ", i, "/", experiment$nIter0,
    " basin=", basinID,
    " KGEc=", KGEc[i],
    " elapsed=", elapsed, "s"
  )
}


# ==============================================================================
# Save initial ensemble results
# ==============================================================================

iter0 <- list(
  basinID = basinID,
  zDecision = zDecision,
  parameter_names = info$names,
  params_normalized = lhsParams,
  KGE_calibration = KGEc,
  KGE_evaluation = KGEe,
  qMetrics = metrics,
  seed = experiment$seed
)

outdir <- ensure_dir(file.path(paths$iter0, paste0("zDecision_", zDecision), basinID))

save(
  iter0,
  file = file.path(outdir, paste0("iter0_", basinID, "_zDec_", zDecision, ".RData"))
)