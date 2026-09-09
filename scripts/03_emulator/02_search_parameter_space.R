#!/usr/bin/env Rscript

# ==============================================================================
# Search the parameter space with a trained Large-Sample Emulator
#
# For one basin and one emulator iteration, this script searches the normalized
# FUSE parameter space with a genetic algorithm. Candidate parameter sets are
# ranked by emulator-predicted NKGE and saved for subsequent FUSE evaluation.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 6L) {
  stop("Usage: Rscript 02_search_parameter_space.R <basinID> <experiment_dir> <zDecision> <modelStep> <phase:train|test> <dirMain>")
}

basinID <- as.character(args[1])
experiment_dir <- normalizePath(args[2], mustWork = TRUE)
zDecision <- args[3]
modelStep <- as.integer(args[4])
phase <- args[5]
dirMain <- normalizePath(args[6], mustWork = TRUE)

if (!phase %in% c("train", "test")) {
  stop("phase must be train or test")
}


# ==============================================================================
# Functions, packages and configuration
# ==============================================================================

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/emulator.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain, experiment)

suppressPackageStartupMessages({
  library(GA)
  library(lhs)
  library(ranger)
  library(xgboost)
  library(Matrix)
})


# ==============================================================================
# Basin attributes and output directories
# ==============================================================================

attrs <- load_rdata_single(file.path(paths$useful, "attributes.RData"))

row <- which(as.character(attrs$ID) == basinID)

if (length(row) != 1L) {
  stop("No unique attributes row for ", basinID)
}

model_dir <- file.path(experiment_dir, "outputs", paste0("zDecision_", zDecision), "models")
out_dir <- ensure_dir(file.path(experiment_dir, "outputs", paste0("zDecision_", zDecision), phase, basinID))

all_results <- list()


# ==============================================================================
# Search the parameter space for each emulator
# ==============================================================================

for (ml in experiment$emulators) {
  
  model_file <- file.path(model_dir, paste0("emulator_step_", modelStep, "_", ml, ".RData"))
  summary <- load_rdata_single(model_file)
  
  rec <- summary$preprocessing
  nParams <- length(rec$parameter_names)
  
  # Use exactly the static attributes retained when this emulator was trained.
  att <- attrs[row, rec$attribute_names, drop = FALSE]
  
  if (anyNA(att)) {
    stop("Missing target-basin attributes required by model: ", basinID)
  }
  
  # Emulator fitness for one normalized FUSE parameter vector.
  fitness <- function(x) {
    
    d <- as.data.frame(matrix(x, nrow = 1))
    names(d) <- paste0("p", seq_len(nParams))
    d <- cbind(d, att)
    
    y <- predict_emulator(summary, d)
    
    if (!is.finite(y)) -1 else y
  }
  
  # Keep the GA search reproducible while using a different seed for each
  # emulator and refinement step.
  set.seed(experiment$seed + modelStep + match(ml, experiment$emulators))
  
  ga <- GA::ga(
    type = "real-valued",
    fitness = fitness,
    lower = rep(0, nParams),
    upper = rep(1, nParams),
    popSize = experiment$ga_population,
    maxiter = experiment$ga_generations,
    suggestions = lhs::randomLHS(experiment$ga_population, nParams),
    run = ceiling(2 * experiment$ga_generations / 3),
    optim = TRUE,
    parallel = FALSE,
    monitor = FALSE
  )
  
  # Retain the best unique candidates found in the final GA population.
  p <- as.data.frame(ga@population)
  names(p) <- paste0("p", seq_len(nParams))
  
  p[] <- lapply(p, function(x) pmin(1, pmax(0, x))) # needed to avoid numerical issues
  
  p$eNKGE <- as.numeric(ga@fitness)
  
  p <- unique(p)
  p <- p[order(p$eNKGE, decreasing = TRUE, na.last = NA), , drop = FALSE]
  p <- head(p, experiment$nCandidates)
  
  p$rank <- seq_len(nrow(p))
  p$optAlg <- "GA"
  p$emulator <- ml
  p$model_step <- modelStep
  p$phase <- phase
  
  all_results[[ml]] <- p
}


# ==============================================================================
# Save candidate parameter sets
#
# During refinement, the candidate step corresponds to the emulator model step.
# In the final test phase, the same convention is kept for consistency.
# ==============================================================================

paramSearch <- do.call(rbind, all_results)
rownames(paramSearch) <- NULL

save(
  paramSearch,
  file = file.path(out_dir, paste0("candidates_step_", modelStep, ".RData"))
)