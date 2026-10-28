#!/usr/bin/env Rscript

# ==============================================================================
# Run FUSE for candidate parameter sets proposed by the emulator
#
# Each candidate is evaluated with the real FUSE model. Calibration and
# evaluation KGE values are stored alongside the emulator prediction so that
# candidate quality can be assessed independently of the surrogate model.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 8L) {
  stop("Usage: Rscript 03_run_FUSE_candidates.R <basinID> <experiment_dir> <zDecision> <modelStep> <phase> <work_dir> <config_file> <dirMain> [--emulator RF,GBMv02] [--resume]")
}

basinID <- as.character(args[1])
experiment_dir <- normalizePath(args[2], mustWork = TRUE)
zDecision <- args[3]
modelStep <- as.integer(args[4])
phase <- args[5]
work_dir <- args[6]
config_file <- normalizePath(args[7], mustWork = TRUE)
dirMain <- normalizePath(args[8], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/emulator_data.R"))

experiment <- load_workflow_config(config_file)

# Resolve selected methods without modifying the scientific config.
optional_args <- if (length(args) > 8L) args[-seq_len(8L)] else character()

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

suppressPackageStartupMessages(library(ncdf4))


# ==============================================================================
# FUSE configuration and candidate parameter sets
# ==============================================================================

meta <- load_rdata_single(file.path(paths$useful, "fuse_settings_files.RData"))
info <- get_parameter_info(meta, zDecision)

colsX <- paste0("p", seq_along(info$names))



fuse_resume_status <- function(
  out_dir, step, method, phase,
  zDecision, colsX, work_dir = NULL
) {

  legacy <- file.path(
    out_dir,
    sprintf("candidates_step_%d.RData", step)
  )

  individual <- file.path(
    out_dir,
    sprintf("candidates_step_%d_%s.RData", step, method)
  )

  invalid_path <- function(path) {
    link <- Sys.readlink(path)

    dir.exists(path) ||
      (!is.na(link) && nzchar(link))
  }

  if (invalid_path(legacy) ||
      invalid_path(individual)) {
    return("STOP")
  }

  has_legacy <- file.exists(legacy)
  has_individual <- file.exists(individual)

  if (has_legacy && has_individual) {
    return("STOP")
  }

  # FUSE cannot start without GA candidates.
  if (!has_legacy && !has_individual) {
    return("STOP")
  }

  candidate <- tryCatch(
    suppressWarnings(
      read_emulator_candidates(
        out_dir, step, method
      )
    ),
    error = function(e) NULL
  )

  if (is.null(candidate) ||
      !is.list(candidate) ||
      !is.data.frame(candidate$data)) {
    return("STOP")
  }

  x <- candidate$data

  required_ga <- c(
    colsX, "emulator", "model_step",
    "phase", "rank", "eNKGE"
  )

  if (!nrow(x) ||
      !all(required_ga %in% names(x))) {
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

  for (p in colsX) {
    if (!is.numeric(x[[p]]) ||
        any(!is.finite(x[[p]])) ||
        any(x[[p]] < 0 | x[[p]] > 1)) {
      return("STOP")
    }
  }

  evaluation_fields <- c(
    "qMetrics",
    "run_ok",
    "run_reason",
    "runTime_sec",
    "KGEc",
    "KGEe",
    "NKGEc",
    "zDecision"
  )

  existing <- intersect(
    evaluation_fields,
    names(x)
  )

  # A complete GA file, without FUSE evaluations.
  if (!length(existing)) {

    # Historical combined files remain read-only.
    if (!identical(candidate$format, "individual")) {
      return("STOP")
    }

    # Existing workspaces cannot be silently reused.
    if (!is.null(work_dir)) {
      method_workspace <- file.path(work_dir, method)

      if (file.exists(method_workspace) ||
          dir.exists(method_workspace) ||
          (!is.na(Sys.readlink(method_workspace)) && nzchar(Sys.readlink(method_workspace)))) {
        return("STOP")
      }
    }

    return("RUN")
  }

  # Some evaluation columns but not all: unsafe.
  if (length(existing) != length(evaluation_fields)) {
    return("STOP")
  }

  n <- nrow(x)

  if (!is.logical(x$run_ok) ||
      length(x$run_ok) != n ||
      anyNA(x$run_ok)) {
    return("STOP")
  }

  if (!is.character(x$run_reason) ||
      length(x$run_reason) != n ||
      anyNA(x$run_reason) ||
      any(!nzchar(trimws(x$run_reason)))) {
    return("STOP")
  }

  if (any(x$run_ok & x$run_reason != "ok") ||
      any(!x$run_ok & x$run_reason == "ok")) {
    return("STOP")
  }

  if (!is.numeric(x$runTime_sec) ||
      length(x$runTime_sec) != n ||
      any(!is.finite(x$runTime_sec)) ||
      any(x$runTime_sec < 0)) {
    return("STOP")
  }

  for (field in c("KGEc", "KGEe", "NKGEc")) {
    if (!is.numeric(x[[field]]) ||
        length(x[[field]]) != n) {
      return("STOP")
    }
  }

  if (!is.list(x$qMetrics) ||
      length(x$qMetrics) != n) {
    return("STOP")
  }

  for (i in which(x$run_ok)) {
    if (is.null(x$qMetrics[[i]]) ||
        !length(x$qMetrics[[i]])) {
      return("STOP")
    }
  }

  if ("qSim" %in% names(x) &&
      (!is.list(x$qSim) ||
       length(x$qSim) != n)) {
    return("STOP")
  }

  if (anyNA(x$zDecision) ||
      any(as.character(x$zDecision) !=
          as.character(zDecision))) {
    return("STOP")
  }

  "SKIP"
}

out_dir <- file.path(experiment_dir, "outputs", paste0("zDecision_", zDecision), phase, basinID)

methods_to_evaluate <- selected_emulators

if (resume) {

  states <- setNames(
    vapply(selected_emulators, function(ml) {
      fuse_resume_status(
        out_dir = out_dir,
        step = modelStep,
        method = ml,
        phase = phase,
        zDecision = zDecision,
        colsX = colsX,
        work_dir = work_dir
      )
    }, character(1L)),
    selected_emulators
  )

  for (ml in names(states)) {
    message("RESUME FUSE ", ml, ": ", states[[ml]])
  }

  invalid <- !states %in% c("SKIP", "RUN")

  if (any(invalid)) {
    stop(
      "Resume refused: invalid or ambiguous FUSE evaluation: ",
      paste(names(states)[invalid], collapse = ", ")
    )
  }

  methods_to_evaluate <- names(states)[states == "RUN"]
}

# Evaluate and save each emulator independently.
# The lock covers loading, FUSE evaluation and commit.

for (ml in methods_to_evaluate) {

  file_candidates <- file.path(
    out_dir,
    paste0("candidates_step_", modelStep, "_", ml, ".RData")
  )

  with_candidate_lock(file_candidates, {

    if (resume) {
      locked_state <- fuse_resume_status(
        out_dir = out_dir,
        step = modelStep,
        method = ml,
        phase = phase,
        zDecision = zDecision,
        colsX = colsX,
        work_dir = work_dir
      )

      if (!identical(locked_state, "RUN")) {
        stop(
          "FUSE candidate state changed before evaluation: ",
          ml, " (", locked_state, ")"
        )
      }
    }


    candidate <- read_emulator_candidates(
      out_dir, modelStep, ml
    )

    if (!identical(candidate$format, "individual")) {
      stop("Historical candidates are read-only: ", candidate$source_file)
    }

    paramSearch <- candidate$data

    required <- c(
      colsX, "emulator", "model_step",
      "phase", "rank", "eNKGE"
    )

    if (!all(required %in% names(paramSearch)) ||
        anyNA(paramSearch$phase) ||
        any(paramSearch$phase != phase) ||
        anyNA(paramSearch$rank) ||
        anyDuplicated(paramSearch$rank) ||
        sum(paramSearch$rank == 1L) != 1L) {
      stop("Invalid candidate structure for ", ml)
    }

    method_work_dir <- file.path(work_dir, ml)

    if (file.exists(method_work_dir)) {
      stop("FUSE workspace already exists: ", method_work_dir)
    }

  evaluation_columns <- c(
    "run_ok", "run_reason", "runTime_sec",
    "KGEc", "KGEe", "NKGEc"
  )

  existing_evaluation <- intersect(
    evaluation_columns,
    names(paramSearch)
  )

  if (length(existing_evaluation) > 0L) {
    stop(
      "Candidate file already contains FUSE evaluation fields: ",
      file_candidates,
      "\nExisting fields: ",
      paste(existing_evaluation, collapse = ", "),
      "\nRefusing to reevaluate existing candidate results."
    )
  }


  # ==============================================================================
  # FUSE workspace and observed streamflow
  # ==============================================================================

  prepare_fuse_workspace(dirMain, method_work_dir, basinID, zDecision, experiment)

  qObs <- read_qobs(file.path(method_work_dir, "input", paste0(basinID, "_input.nc")), experiment)
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
      method_work_dir,
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

    # Commit this emulator before processing the next.
    save_candidate_atomic(
      paramSearch,
      file_candidates,
      replace = TRUE
    )

  })
}
