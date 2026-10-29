#!/usr/bin/env Rscript

# ==============================================================================
# Run the initial FUSE parameter ensemble for one basin
#
# The initial ensemble is sampled with Latin Hypercube Sampling over the active
# parameter space of the selected FUSE configuration. Each parameter set is run
# with FUSE and evaluated over the calibration and evaluation periods.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- paste(
  "Usage: Rscript 01_run_iter0.R",
  "<basinID> <zDecision> <work_dir> <config_file> <dirMain>",
  "--timestep <daily|hourly> [--force]"
)

if (
  !(length(args) %in% c(7L, 8L)) ||
  args[6] != "--timestep" ||
  (length(args) == 8L && args[8] != "--force")
) {
  stop(usage)
}

workflow_timestep <- args[7]

if (!(workflow_timestep %in% c("daily", "hourly"))) {
  stop("Invalid --timestep: ", workflow_timestep, ". ", usage)
}

force <- length(args) == 8L

basinID <- as.character(args[1])
zDecision <- as.character(args[2])
work_dir <- args[3]
config_file <- normalizePath(args[4], mustWork = TRUE)
dirMain <- normalizePath(args[5], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))

experiment <- load_workflow_config(
  config_file,
  timestep = workflow_timestep
)
paths <- project_paths(dirMain, experiment)

# Check that the selected basin belongs to this experiment.
selected_basins <- as.character(
  read_basin_ids(file.path(dirMain, "config", "basins.txt"))
)

if (!basinID %in% selected_basins) {
  stop("Basin ", basinID, " is not listed in config/basins.txt")
}

# An explicit zDecision must belong to the configured model structures.
configured_decisions <- as.character(experiment$zDecision)

if (
  !length(configured_decisions) ||
  anyNA(configured_decisions) ||
  any(!nzchar(trimws(configured_decisions)))
) {
  stop("Invalid experiment$zDecision configuration")
}

if (!zDecision %in% configured_decisions) {
  stop(
    "zDecision ", zDecision,
    " is not allowed by the experiment configuration. Allowed: ",
    paste(configured_decisions, collapse = ", ")
  )
}

# Protect the immutable initial ensemble against accidental replacement.
iter0_file <- file.path(
  paths$iter0,
  paste0("zDecision_", zDecision),
  basinID,
  paste0("iter0_", basinID, "_zDec_", zDecision, ".RData")
)

if (file.exists(iter0_file) && !force) {
  stop(
    "Iter0 result already exists: ", iter0_file,
    "\nUse --force to explicitly allow recalculation."
  )
}

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

outdir <- ensure_dir(dirname(iter0_file))

# Write and validate the complete result before making it visible.
temporary_file <- tempfile(
  pattern = ".iter0_",
  tmpdir = outdir,
  fileext = ".RData"
)

tryCatch(
  {
    save(iter0, file = temporary_file)

    # Ensure the newly written RData file can be loaded.
    invisible(load_rdata_single(temporary_file))

    # Recheck immediately before finalizing the result.
    if (file.exists(iter0_file) && !force) {
      stop("Iter0 result already exists: ", iter0_file)
    }

    if (!file.rename(temporary_file, iter0_file)) {
      stop("Could not finalize iter0 result: ", iter0_file)
    }
  },
  finally = {
    if (file.exists(temporary_file)) {
      unlink(temporary_file)
    }
  }
)
