#!/usr/bin/env Rscript

# Evaluate one existing FUSE simulation.
# No FUSE execution and no comparison with another simulation.

args <- commandArgs(trailingOnly = TRUE)

force <- length(args) == 3L && args[3] == "--force"
check_only <- length(args) == 3L && args[3] == "--check"

if (
  !(length(args) == 2L || force || check_only)
) {
  stop(
    "Usage: Rscript 01_evaluate_FUSE.R ",
    "<hydrograph_dir> <dirMain> [--check|--force]"
  )
}

hydro_dir <- normalizePath(args[1], mustWork = TRUE)
dirMain <- normalizePath(args[2], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/flood_metrics.R"))
source(file.path(dirMain, "scripts/functions/flood_evaluation.R"))
source(file.path(dirMain, "scripts/functions/evaluation_series.R"))

sim_file <- file.path(hydro_dir, "qSim_selected.rds")
meta_file <- file.path(hydro_dir, "metadata.rds")

if (!file.exists(sim_file) || !file.exists(meta_file)) {
  stop("Missing saved simulation or metadata: ", hydro_dir)
}

meta <- readRDS(meta_file)

required_meta <- c(
  "experiment_dir", "config_file", "basinID",
  "zDecision", "modelStep", "phase", "emulator"
)

stopifnot(all(required_meta %in% names(meta)))

# Verify that metadata identifies the actual simulation directory.
expected_hydro_dir <- file.path(
  meta$experiment_dir,
  "hydrographs",
  paste0("zDecision_", meta$zDecision),
  meta$phase,
  as.character(meta$basinID),
  paste0("step_", meta$modelStep),
  meta$emulator
)

if (!identical(
  hydro_dir,
  normalizePath(expected_hydro_dir, mustWork = TRUE)
)) {
  stop("Hydrograph directory does not match saved metadata")
}

experiment <- load_workflow_config(meta$config_file)
stopifnot(experiment$timestep %in% c("hourly", "daily"))

basinID <- as.character(meta$basinID)

# ==================================================
# 1. Persistent output location
# ==================================================

out_dir <- file.path(
  meta$experiment_dir,
  "evaluation",
  paste0("zDecision_", meta$zDecision),
  meta$phase,
  basinID,
  paste0("step_", meta$modelStep),
  meta$emulator
)

expected_names <- c("global_native.csv", "flood_native.csv")

if (experiment$timestep == "hourly") {
  expected_names <- c(
    expected_names,
    "global_daily.csv",
    "flood_daily.csv"
  )
}

expected_names <- c(expected_names, "metadata.rds")

if (dir.exists(out_dir) && !check_only) {
  existing <- list.files(out_dir, all.files = TRUE, no.. = TRUE)

  if (length(existing) && !force) {
    stop(
      "Evaluation results already exist: ", out_dir,
      "\nUse --force to explicitly allow replacement."
    )
  }

  unexpected <- setdiff(existing, expected_names)

  if (length(unexpected)) {
    stop(
      "Unexpected files in evaluation directory: ",
      paste(unexpected, collapse = ", ")
    )
  }
}

# ==================================================
# 2. Load one simulation and native observations
# ==================================================

qsim <- readRDS(sim_file)

stopifnot(
  is.data.frame(qsim),
  all(c("time", "qSim") %in% names(qsim)),
  inherits(qsim$time, "POSIXct"),
  is.numeric(qsim$qSim),
  nrow(qsim) > 0L,
  !anyDuplicated(qsim$time)
)

obs_file <- function(timestep) {
  file.path(
    dirMain, "data", "forcings", timestep,
    basinID, paste0(basinID, "_input.nc")
  )
}

qobs_native <- read_qobs(
  obs_file(experiment$timestep),
  experiment
)

periods <- metric_periods_from_config(experiment)

# Evaluate flood events independently in calibration and evaluation periods.
evaluate_flood_periods <- function(evaluator) {
  out <- lapply(names(periods), function(period_name) {
    p <- periods[[period_name]]

    x <- evaluator(p$ti, p$tf)
    x$period <- rep(period_name, nrow(x))

    x[, c("period", setdiff(names(x), "period")), drop = FALSE]
  })

  do.call(rbind, out)
}

# ==================================================
# 3. Global metrics at native resolution
# ==================================================

global_native <- compute_flow_metrics(
  qsim,
  qobs_native,
  basinID,
  periods
)

if (is.null(global_native)) {
  stop("Insufficient data for native global metrics")
}

results <- list(global_native = global_native)

# ==================================================
# 4. Native flood events / daily flood units
# ==================================================

units <- read.csv(
  file.path(
    dirMain, "data", "flood", "qc",
    "observed_flood_daily_units.csv"
  ),
  stringsAsFactors = FALSE
)

if (experiment$timestep == "hourly") {

  events <- read.csv(
    file.path(
      dirMain, "data", "flood", "qc",
      "observed_flood_catalogue_reviewed.csv"
    ),
    stringsAsFactors = FALSE
  )

  results$flood_native <- evaluate_flood_periods(function(ti, tf) {
    evaluate_hourly_flood_events(
      qobs_hourly = qobs_native,
      qsim_hourly = qsim,
      events = events,
      basin_id = basinID,
      evaluation_start = ti,
      evaluation_end = tf,
      timezone = experiment$timezone
    )
  })

} else {

  daily <- prepare_daily_evaluation(
    qobs_daily = qobs_native,
    qsim = qsim,
    simulation_timestep = "daily",
    timezone = experiment$timezone
  )

  results$flood_native <- evaluate_flood_periods(function(ti, tf) {
    evaluate_daily_flood_units(
      paired = daily$paired,
      units = units,
      basin_id = basinID,
      evaluation_start = ti,
      evaluation_end = tf,
      timezone = experiment$timezone
    )
  })
}

# ==================================================
# 5. Additional daily evaluation for hourly FUSE
# ==================================================

if (experiment$timestep == "hourly") {

  daily_config <- load_workflow_config(
    file.path(dirMain, "config", "experiment_daily.R")
  )

  stopifnot(
    identical(daily_config$timestep, "daily"),
    identical(daily_config$timezone, experiment$timezone)
  )

  qobs_daily <- read_qobs(
    obs_file("daily"),
    daily_config
  )

  daily <- prepare_daily_evaluation(
    qobs_daily = qobs_daily,
    qsim = qsim,
    simulation_timestep = "hourly",
    timezone = experiment$timezone
  )

  results$global_daily <- compute_flow_metrics(
    qsim = daily$paired[, c("time", "qSim")],
    qobs = daily$paired[, c("time", "qObs")],
    basinID = basinID,
    periods = periods
  )

  if (is.null(results$global_daily)) {
    stop("Insufficient data for aggregated daily global metrics")
  }

  results$flood_daily <- evaluate_flood_periods(function(ti, tf) {
    evaluate_daily_flood_units(
      paired = daily$paired,
      units = units,
      basin_id = basinID,
      evaluation_start = ti,
      evaluation_end = tf,
      timezone = experiment$timezone
    )
  })
}

# ==================================================
# 6. Save only after successful evaluation
# ==================================================

stopifnot(all(vapply(
  names(results),
  function(name) {
    x <- results[[name]]
    is.data.frame(x) &&
      (nrow(x) > 0L || startsWith(name, "flood_"))
  },
  logical(1)
)))

if (check_only) {
  cat("\n===== EVALUATION CHECK =====\n")

  for (name in names(results)) {
    x <- results[[name]]

    cat("\n", name, ": ", nrow(x), " rows\n", sep = "")

    if ("period" %in% names(x)) {
      print(table(x$period))
    }

    if ("valid" %in% names(x)) {
      cat("Valid:", sum(x$valid), "\n")
      print(table(x$period, x$valid))
    }
  }

  cat("\nCHECK PASSED -- NO FILES WRITTEN\n")
  quit(save = "no", status = 0)
}

evaluation_metadata <- list(
  simulation_file = sim_file,
  simulation_metadata_file = meta_file,
  experiment_dir = meta$experiment_dir,
  config_file = meta$config_file,
  timestep = experiment$timestep,
  basinID = basinID,
  zDecision = meta$zDecision,
  modelStep = meta$modelStep,
  phase = meta$phase,
  emulator = meta$emulator,
  calibration_start = experiment$calibration_start,
  calibration_end = experiment$calibration_end,
  evaluation_start = experiment$evaluation_start,
  evaluation_end = experiment$evaluation_end
)

# Stage the complete evaluation before publishing persistent results.
publish_evaluation <- function(results, metadata, out_dir, force) {

  parent <- dirname(out_dir)
  dir.create(parent, recursive = TRUE, showWarnings = FALSE)

  stage <- tempfile(
    pattern = paste0(".", basename(out_dir), "_stage_"),
    tmpdir = parent
  )

  if (!dir.create(stage)) {
    stop("Cannot create staging directory: ", stage)
  }

  on.exit({
    if (dir.exists(stage)) {
      unlink(stage, recursive = TRUE)
    }
  }, add = TRUE)

  for (name in names(results)) {
    write.csv(
      results[[name]],
      file.path(stage, paste0(name, ".csv")),
      row.names = FALSE
    )
  }

  saveRDS(metadata, file.path(stage, "metadata.rds"))

  expected <- c(paste0(names(results), ".csv"), "metadata.rds")
  written <- list.files(stage)

  if (!setequal(written, expected)) {
    stop("Incomplete staged evaluation")
  }

  if (file.exists(out_dir) && !dir.exists(out_dir)) {
    stop("Evaluation destination is not a directory: ", out_dir)
  }

  if (dir.exists(out_dir)) {

    existing <- list.files(
      out_dir, all.files = TRUE, no.. = TRUE
    )

    if (length(existing) && !force) {
      stop("Existing evaluation cannot be overwritten: ", out_dir)
    }

    unexpected <- setdiff(existing, expected_names)

    if (length(unexpected)) {
      stop(
        "Unexpected existing evaluation files: ",
        paste(unexpected, collapse = ", ")
      )
    }

    backup <- tempfile(
      pattern = paste0(".", basename(out_dir), "_backup_"),
      tmpdir = parent
    )

    if (!file.rename(out_dir, backup)) {
      stop("Cannot back up existing evaluation: ", out_dir)
    }

    if (!file.rename(stage, out_dir)) {

      if (!file.rename(backup, out_dir)) {
        stop(
          "Publication and restoration failed. Backup retained at: ",
          backup
        )
      }

      stop("Evaluation publication failed; previous results restored")
    }

    if (unlink(backup, recursive = TRUE) != 0L) {
      warning("Old evaluation backup could not be removed: ", backup)
    }

  } else {

    if (!file.rename(stage, out_dir)) {
      stop("Cannot publish evaluation: ", out_dir)
    }
  }

  invisible(out_dir)
}

publish_evaluation(
  results = results,
  metadata = evaluation_metadata,
  out_dir = out_dir,
  force = force
)

cat("\n===== EVALUATION SUMMARY =====\n")
cat("Basin:", basinID, "\n")
cat("Resolution:", experiment$timestep, "\n")
cat("Output:", out_dir, "\n")

for (name in names(results)) {
  cat(
    name, ":",
    nrow(results[[name]]), "rows",
    if ("valid" %in% names(results[[name]])) {
      paste0(" (", sum(results[[name]]$valid), " valid)")
    } else {
      ""
    },
    "\n"
  )
}

cat("\nFUSE EVALUATION COMPLETE\n")
