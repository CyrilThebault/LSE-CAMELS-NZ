#!/usr/bin/env Rscript

# ==============================================================================
# Search the parameter space with a trained Large-Sample Emulator
#
# For one basin and one emulator iteration, this script searches the normalized
# FUSE parameter space with a genetic algorithm. Candidate parameter sets are
# ranked by emulator-predicted NKGE and saved for subsequent FUSE evaluation.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 7L) {
  stop("Usage: Rscript 02_search_parameter_space.R <basinID> <experiment_dir> <zDecision> <modelStep> <phase:train|test> <config_file> <dirMain> [--emulator RF,GBMv02] [--resume]")
}

basinID <- as.character(args[1])
experiment_dir <- normalizePath(args[2], mustWork = TRUE)
zDecision <- args[3]
modelStep <- as.integer(args[4])
phase <- args[5]
config_file <- normalizePath(args[6], mustWork = TRUE)
dirMain <- normalizePath(args[7], mustWork = TRUE)

if (!phase %in% c("train", "test")) {
  stop("phase must be train or test")
}


# ==============================================================================
# Functions, packages and configuration
# ==============================================================================

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/emulator_data.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/emulator.R"))

experiment <- load_workflow_config(config_file)

# Select methods for this invocation without changing the configuration.
optional_args <- if (length(args) > 7L) args[-seq_len(7L)] else character()

resume <- "--resume" %in% optional_args

if (sum(optional_args == "--resume") > 1L) {
  stop("Duplicate --resume option")
}

optional_args <- optional_args[optional_args != "--resume"]

emulator_value <- NULL

if (length(optional_args)) {
  if (length(optional_args) != 2L ||
      !identical(optional_args[1L], "--emulator") ||
      !nzchar(optional_args[2L])) {
    stop("Expected --emulator followed by comma-separated methods")
  }
  emulator_value <- optional_args[2L]
}

selected_emulators <- if (is.null(emulator_value)) {
  experiment$emulators
} else {
  if (grepl(",[[:space:]]*$", emulator_value)) {
    stop("Invalid --emulator list: trailing comma")
  }
  trimws(strsplit(emulator_value, ",", fixed = TRUE)[[1L]])
}

if (!length(selected_emulators) ||
    anyNA(selected_emulators) ||
    any(!nzchar(selected_emulators)) ||
    anyDuplicated(selected_emulators) ||
    any(!selected_emulators %in% experiment$emulators)) {
  stop("Invalid or duplicate emulator selection")
}
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

# Protect existing candidate files, including completed FUSE evaluations.
# Check before starting the potentially expensive parameter search.


ga_resume_status <- function(
  out_dir, step, method, phase, model_dir
) {

  legacy <- file.path(
    out_dir,
    sprintf("candidates_step_%d.RData", step)
  )

  individual <- file.path(
    out_dir,
    sprintf(
      "candidates_step_%d_%s.RData",
      step, method
    )
  )

  is_present <- function(path) {
    link <- Sys.readlink(path)

    file.exists(path) ||
      dir.exists(path) ||
      (!is.na(link) && nzchar(link))
  }

  # Refuse symbolic links and directories used
  # in place of candidate files.

  for (path in c(legacy, individual)) {

    link <- Sys.readlink(path)

    if ((!is.na(link) && nzchar(link)) ||
        dir.exists(path)) {
      return("STOP")
    }
  }

  has_legacy <- is_present(legacy)
  has_individual <- is_present(individual)

  # Never mix historical combined candidates
  # and new individual candidates for the same
  # method and step.

  if (has_legacy && has_individual) {
    return("STOP")
  }

  if (!has_legacy && !has_individual) {
    return("RUN")
  }

  candidate <- tryCatch(
    read_emulator_candidates(
      out_dir, step, method
    ),
    error = function(e) NULL
  )

  if (is.null(candidate) ||
      !is.list(candidate) ||
      !is.data.frame(candidate$data)) {
    return("STOP")
  }

  x <- candidate$data

  required <- c(
    "emulator",
    "model_step",
    "phase",
    "rank",
    "eNKGE"
  )

  if (nrow(x) == 0L ||
      !all(required %in% names(x))) {
    return("STOP")
  }

  if (anyNA(x$emulator) ||
      any(as.character(x$emulator) != method) ||
      anyNA(x$model_step) ||
      any(as.character(x$model_step) != as.character(step)) ||
      anyNA(x$phase) ||
      any(as.character(x$phase) != phase)) {
    return("STOP")
  }

  if (!is.numeric(x$rank) ||
      anyNA(x$rank) ||
      anyDuplicated(x$rank) ||
      sum(x$rank == 1L) != 1L ||
      !is.numeric(x$eNKGE) ||
      any(!is.finite(x$eNKGE))) {
    return("STOP")
  }

  # Ensure candidates match the trained emulator's
  # parameter dimension and normalized FUSE domain.
  model_file <- file.path(
    model_dir,
    paste0("emulator_step_", step, "_", method, ".RData")
  )

  model_summary <- tryCatch(
    suppressWarnings(load_rdata_single(model_file)),
    error = function(e) NULL
  )

  if (!is.list(model_summary) ||
      !is.list(model_summary$preprocessing)) {
    return("STOP")
  }

  parameter_names <- model_summary$preprocessing$parameter_names

  if (!is.character(parameter_names) ||
      !length(parameter_names) ||
      anyNA(parameter_names) ||
      anyDuplicated(parameter_names)) {
    return("STOP")
  }

  expected <- paste0("p", seq_along(parameter_names))
  actual <- grep("^p[0-9]+$", names(x), value = TRUE)

  if (length(actual) != length(expected) ||
      !setequal(actual, expected)) {
    return("STOP")
  }

  for (p in expected) {
    values <- x[[p]]

    if (!is.numeric(values) ||
        any(!is.finite(values)) ||
        any(values < 0 | values > 1)) {
      return("STOP")
    }
  }

  # GA output may already contain FUSE evaluations.
  # If such fields exist, reject a partially
  # populated evaluation schema.

  evaluation_fields <- c(
    "run_ok",
    "run_reason",
    "runTime_sec",
    "KGEc",
    "KGEe",
    "NKGEc"
  )

  existing <- intersect(
    evaluation_fields,
    names(x)
  )

  if (length(existing) > 0L &&
      length(existing) != length(evaluation_fields)) {
    return("STOP")
  }

  "SKIP"
}


legacy_file <- file.path(
  out_dir,
  paste0("candidates_step_", modelStep, ".RData")
)

if (!resume && file.exists(legacy_file)) {
  stop("Historical candidate file already exists: ", legacy_file)
}


methods_to_search <- selected_emulators

if (resume) {

  states <- setNames(
    vapply(selected_emulators, function(ml) {
      ga_resume_status(
        out_dir = out_dir,
        step = modelStep,
        method = ml,
        phase = phase,
        model_dir = model_dir
      )
    }, character(1L)),
    selected_emulators
  )

  for (ml in names(states)) {
    message("RESUME GA ", ml, ": ", states[[ml]])
  }

  if (any(states == "STOP")) {
    stop(
      "Resume refused: invalid or ambiguous GA candidates: ",
      paste(names(states)[states == "STOP"], collapse = ", ")
    )
  }

  methods_to_search <- names(states)[states == "RUN"]
}

# Evaluate and save each emulator independently under its own lock.


# ==============================================================================
# Search the parameter space for each emulator
# ==============================================================================

for (ml in methods_to_search) {

  file_candidates <- file.path(
    out_dir,
    paste0("candidates_step_", modelStep, "_", ml, ".RData")
  )

  with_candidate_lock(file_candidates, {

    if (file.exists(legacy_file)) {
      stop("Historical candidate file already exists: ", legacy_file)
    }

    if (file.exists(file_candidates)) {
      stop("Candidate file already exists: ", file_candidates)
    }


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

  # Preserve the pre-refactor method- and step-specific GA seed.
  # The configured emulator order defines the deterministic mapping.
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


    paramSearch <- p
    rownames(paramSearch) <- NULL

    save_candidate_atomic(
      paramSearch,
      file_candidates,
      replace = FALSE
    )

  })
}
