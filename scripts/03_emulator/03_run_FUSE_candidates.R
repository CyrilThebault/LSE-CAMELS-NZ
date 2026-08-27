#!/usr/bin/env Rscript

# ==============================================================================
# Run FUSE for candidate parameter sets proposed by the emulator
#
# Each candidate is evaluated with the real FUSE model. Calibration and
# evaluation KGE values are stored alongside the emulator prediction so that
# candidate quality can be assessed independently of the surrogate model.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 7L) {
  stop("Usage: Rscript 03_run_FUSE_candidates.R <basinID> <experiment_dir> <zDecision> <modelStep> <phase> <work_dir> <dirMain>")
}

basinID <- as.character(args[1])
experiment_dir <- normalizePath(args[2], mustWork = TRUE)
zDecision <- args[3]
modelStep <- as.integer(args[4])
phase <- args[5]
work_dir <- args[6]
dirMain <- normalizePath(args[7], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain)

suppressPackageStartupMessages(library(ncdf4))


# ==============================================================================
# FUSE configuration and candidate parameter sets
# ==============================================================================

meta <- load_rdata_single(file.path(paths$useful, "fuse_settings_files.RData"))
info <- get_parameter_info(meta, zDecision)

colsX <- paste0("p", seq_along(info$names))

out_dir <- file.path(experiment_dir, "outputs", paste0("zDecision_", zDecision), phase, basinID)
file_candidates <- file.path(out_dir, paste0("candidates_step_", modelStep, ".RData"))

paramSearch <- load_rdata_single(file_candidates)


# ==============================================================================
# FUSE workspace and observed streamflow
# ==============================================================================

prepare_fuse_workspace(dirMain, work_dir, basinID, zDecision, experiment)

qObs <- read_qobs(file.path(work_dir, "input", paste0(basinID, "_input.nc")), experiment)
periods <- metric_periods_from_config(experiment)


# ==============================================================================
# Initialise FUSE evaluation results
# ==============================================================================

paramSearch$qMetrics <- vector("list", nrow(paramSearch))

if (experiment$store_hydrographs) {
  paramSearch$qSim <- vector("list", nrow(paramSearch))
}

paramSearch$KGEc <- NA_real_
paramSearch$KGEe <- NA_real_
paramSearch$runTime_sec <- NA_real_
paramSearch$run_ok <- FALSE
paramSearch$run_reason <- NA_character_


# ==============================================================================
# Evaluate each candidate with FUSE
# ==============================================================================

for (i in seq_len(nrow(paramSearch))) {
  
  t0 <- Sys.time()
  
  res <- run_fuse(
    as.numeric(paramSearch[i, colsX]),
    basinID,
    zDecision,
    meta,
    work_dir,
    qObs,
    periods,
    experiment
  )
  
  paramSearch$runTime_sec[i] <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  paramSearch$run_ok[i] <- isTRUE(res$ok)
  paramSearch$run_reason[i] <- if (isTRUE(res$ok)) "ok" else res$reason
  
  if (isTRUE(res$ok)) {
    
    paramSearch$qMetrics[[i]] <- res$qMetrics
    
    paramSearch$KGEc[i] <- res$qMetrics$KGE.2009[
      res$qMetrics$period == "calibration"
    ]
    
    paramSearch$KGEe[i] <- res$qMetrics$KGE.2009[
      res$qMetrics$period == "evaluation"
    ]
    
    if (experiment$store_hydrographs) {
      paramSearch$qSim[[i]] <- res$qSim
    }
  }
}


# ==============================================================================
# Final metrics and save
# ==============================================================================

paramSearch$NKGEc <- nkge(paramSearch$KGEc)
paramSearch$zDecision <- zDecision

save(paramSearch, file = file_candidates)