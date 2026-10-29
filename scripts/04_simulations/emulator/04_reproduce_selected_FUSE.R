#!/usr/bin/env Rscript

# Reproduce and save the rank-1 FUSE simulation for one
# basin, emulator, experiment, model step and phase.

args <- commandArgs(trailingOnly = TRUE)

usage <- paste(
  "Usage: Rscript 04_reproduce_selected_FUSE.R",
  "<basinID> <experiment_dir> <zDecision>",
  "<modelStep> <phase> <emulator> <check|run>",
  "<work_dir> <config_file> <dirMain>",
  "--timestep <daily|hourly>"
)

if (length(args) != 12L || !identical(args[11L], "--timestep")) {
  stop(usage)
}

workflow_timestep <- args[12L]

if (!(workflow_timestep %in% c("daily", "hourly"))) {
  stop("Invalid --timestep: ", workflow_timestep, ". Expected daily or hourly")
}

basinID <- as.character(args[1])
experiment_dir <- normalizePath(args[2], mustWork = TRUE)
zDecision <- args[3]
modelStep <- as.integer(args[4])
phase <- args[5]
emulator <- args[6]
action <- args[7]
work_dir <- path.expand(args[8])
config_file <- normalizePath(args[9], mustWork = TRUE)
dirMain <- normalizePath(args[10], mustWork = TRUE)

stopifnot(
  !is.na(modelStep), modelStep >= 0L,
  phase %in% c("train", "test"),
  action %in% c("check", "run")
)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/emulator_data.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))

experiment <- load_workflow_config(
  config_file,
  timestep = workflow_timestep
)
paths <- project_paths(dirMain, experiment)

stopifnot(emulator %in% experiment$emulators)

# ==================================================
# 1. Select the archived best candidate
# ==================================================

meta <- load_rdata_single(
  file.path(paths$useful, "fuse_settings_files.RData")
)

info <- get_parameter_info(meta, zDecision)
colsX <- paste0("p", seq_along(info$names))

candidate_dir <- file.path(
  experiment_dir, "outputs",
  paste0("zDecision_", zDecision),
  phase, basinID
)

candidate <- read_emulator_candidates(
  candidate_dir, modelStep, emulator
)

ps <- candidate$data

stopifnot(
  is.data.frame(ps),
  all(c(colsX, "emulator", "model_step", "phase",
        "rank", "run_ok", "eNKGE", "KGEc", "KGEe") %in% names(ps))
)

eligible <- which(
  !is.na(ps$emulator) & ps$emulator == emulator &
  !is.na(ps$model_step) & ps$model_step == modelStep &
  !is.na(ps$phase) & ps$phase == phase
)

selected_rows <- eligible[
  !is.na(ps$rank[eligible]) &
  ps$rank[eligible] == 1L
]

stopifnot(length(selected_rows) == 1L)

i <- as.integer(candidate$source_row_indices[selected_rows[1L]])
selected <- ps[selected_rows[1L], , drop = FALSE]
params <- as.numeric(selected[1, colsX])

stopifnot(
  isTRUE(selected$run_ok),
  is.finite(selected$eNKGE),
  all(is.finite(params)),
  all(params >= -1e-12 & params <= 1 + 1e-12),
  all(is.finite(c(selected$KGEc, selected$KGEe)))
)

# ==================================================
# 2. Output files
# ==================================================

# Keep hydrographs separate from archived candidates.
out_dir <- file.path(
  experiment_dir, "hydrographs",
  paste0("zDecision_", zDecision),
  phase, basinID,
  paste0("step_", modelStep),
  emulator
)

sim_file <- file.path(out_dir, "qSim_selected.rds")
meta_file <- file.path(out_dir, "metadata.rds")

cat("\n===== SELECTED CANDIDATE =====\n")
cat("Basin:", basinID, "\n")
cat("Experiment:", experiment_dir, "\n")
cat("Phase:", phase, "\n")
cat("Emulator:", emulator, "\n")
cat("Step:", modelStep, "\n")
cat("zDecision:", zDecision, "\n")
cat("Resolution:", experiment$timestep, "\n")
cat("Selected row:", i, "\n")
cat("Candidate format:", candidate$format, "\n")
cat("Candidate file:", candidate$source_file, "\n")
cat("Archived KGEc:", selected$KGEc, "\n")
cat("Archived KGEe:", selected$KGEe, "\n")
cat("Output:", out_dir, "\n")

if (action == "check") {
  cat("\nPREFLIGHT CHECK PASSED -- NO FUSE EXECUTION\n")
  quit(save = "no", status = 0)
}

# ==================================================
# 3. Reuse an existing simulation if consistent
# ==================================================

valid_sim <- function(x) {
  dt <- get_timestep_info(experiment)$seconds_per_timestep

  is.data.frame(x) &&
    all(c("time", "qSim") %in% names(x)) &&
    inherits(x$time, "POSIXct") &&
    nrow(x) >= 2L &&
    all(is.finite(as.numeric(x$time))) &&
    all(is.finite(x$qSim)) &&
    !anyDuplicated(x$time) &&
    all(abs(diff(as.numeric(x$time)) - dt) < 1e-6)
}

same_number <- function(a, b, tol = 1e-12) {
  isTRUE(all.equal(
    as.numeric(a), as.numeric(b),
    tolerance = tol,
    check.attributes = FALSE
  ))
}

if (file.exists(sim_file) || file.exists(meta_file)) {

  if (!file.exists(sim_file) || !file.exists(meta_file)) {
    stop("Incomplete saved simulation: ", out_dir)
  }

  saved <- readRDS(meta_file)


  qsim <- readRDS(sim_file)

  stopifnot(
    identical(saved$method_type, "emulator"),
    identical(saved$method, emulator),
    identical(saved$candidate_format, candidate$format),
    identical(saved$candidate_file, candidate$source_file),
    identical(saved$experiment_dir, experiment_dir),
    identical(saved$config_file, config_file),
    identical(saved$timestep, experiment$timestep),
    identical(saved$basinID, basinID),
    identical(saved$zDecision, zDecision),
    identical(saved$modelStep, modelStep),
    identical(saved$phase, phase),
    identical(saved$emulator, emulator),
    identical(saved$selected_row, as.integer(i)),
    same_number(saved$params_normalized, params),
    same_number(saved$archived_KGEc, selected$KGEc),
    same_number(saved$archived_KGEe, selected$KGEe),
    same_number(saved$reproduced_KGEc, selected$KGEc, 1e-8),
    same_number(saved$reproduced_KGEe, selected$KGEe, 1e-8),
    valid_sim(qsim)
  )

  cat("\nEXISTING HYDROGRAPH VALIDATED -- NO FUSE EXECUTION\n")
  quit(save = "no", status = 0)
}

if (dir.exists(out_dir) &&
    length(list.files(out_dir, all.files = TRUE, no.. = TRUE))) {
  stop("Output directory is not empty: ", out_dir)
}

# ==================================================
# 4. Reproduce the selected simulation
# ==================================================

if (file.exists(work_dir) || dir.exists(work_dir)) {
  stop("FUSE workspace already exists: ", work_dir)
}

prepare_fuse_workspace(
  dirMain, work_dir, basinID, zDecision, experiment
)

qObs <- read_qobs(
  file.path(work_dir, "input", paste0(basinID, "_input.nc")),
  experiment
)

periods <- metric_periods_from_config(experiment)

experiment$store_hydrographs <- TRUE

cat("\n===== RUNNING FUSE =====\n")

res <- run_fuse(
  params_normalized = params,
  basinID = basinID,
  zDecision = zDecision,
  fuse_settings_files = meta,
  work_dir = work_dir,
  qObs = qObs,
  periods = periods,
  experiment = experiment
)

if (!isTRUE(res$ok)) {
  stop("FUSE failed: ", res$reason)
}

stopifnot(valid_sim(res$qSim))

m <- res$qMetrics

KGEc <- m$KGE.2009[m$period == "calibration"]
KGEe <- m$KGE.2009[m$period == "evaluation"]

stopifnot(
  length(KGEc) == 1L,
  length(KGEe) == 1L,
  all(is.finite(c(KGEc, KGEe)))
)

delta_c <- KGEc - selected$KGEc
delta_e <- KGEe - selected$KGEe

cat("\n===== KGE REPRODUCTION =====\n")

print(data.frame(
  period = c("calibration", "evaluation"),
  archived = c(selected$KGEc, selected$KGEe),
  reproduced = c(KGEc, KGEe),
  difference = c(delta_c, delta_e)
), row.names = FALSE, digits = 15)

# Do not save a simulation that fails reproduction.
stopifnot(
  abs(delta_c) < 1e-8,
  abs(delta_e) < 1e-8
)

# ==================================================
# 5. Save Qsim and minimal metadata
# ==================================================

metadata <- list(
  experiment_dir = experiment_dir,
  config_file = config_file,
  timestep = experiment$timestep,
  method_type = "emulator",
  method = emulator,
  basinID = basinID,
  zDecision = zDecision,
  modelStep = modelStep,
  phase = phase,
  emulator = emulator,
  selected_row = as.integer(i),
  candidate_format = candidate$format,
  candidate_file = candidate$source_file,
  params_normalized = params,
  archived_KGEc = selected$KGEc,
  archived_KGEe = selected$KGEe,
  reproduced_KGEc = KGEc,
  reproduced_KGEe = KGEe
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(out_dir))

# Never overwrite an existing result.
stopifnot(
  !file.exists(sim_file),
  !file.exists(meta_file)
)

saveRDS(res$qSim, sim_file)
saveRDS(metadata, meta_file)

cat("\nHYDROGRAPH SAVED\n")
cat("Qsim:", sim_file, "\n")
cat("Metadata:", meta_file, "\n")
cat("Rows:", nrow(res$qSim), "\n")
cat("FUSE REPRODUCTION VALIDATED\n")
