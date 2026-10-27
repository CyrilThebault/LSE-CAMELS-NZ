#!/usr/bin/env Rscript

# Evaluate archived FUSE simulations from one experiment.
# Default selection: best (final emulator step, test basins;
# or locally calibrated optimum for sce).
# Never runs FUSE or creates missing hydrographs.

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3L) {
  stop(
    "Usage: Rscript 02_evaluate_experiment.R ",
    "<experiment_dir> <config_file> <dirMain> ",
    "[--step N] [--check|--force]"
  )
}

experiment_dir <- normalizePath(args[1], mustWork = TRUE)
config_file <- normalizePath(args[2], mustWork = TRUE)
dirMain <- normalizePath(args[3], mustWork = TRUE)

check_only <- FALSE
force <- FALSE
requested_step <- NULL

options <- args[-(1:3)]
i <- 1L

while (i <= length(options)) {

  option <- options[i]

  if (option == "--check" && !check_only) {
    check_only <- TRUE

  } else if (option == "--force" && !force) {
    force <- TRUE

  } else if (option == "--step" && is.null(requested_step)) {

    if (i == length(options)) {
      stop("--step requires an integer")
    }

    requested_step <- suppressWarnings(
      as.integer(options[i + 1L])
    )

    if (
      is.na(requested_step) ||
      requested_step < 0L
    ) {
      stop("--step must be a non-negative integer")
    }

    i <- i + 1L

  } else {
    stop("Unknown or repeated option: ", option)
  }

  i <- i + 1L
}

if (check_only && force) {
  stop("--check and --force cannot be combined")
}

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(config_file)

stopifnot(
  experiment$timestep %in% c("hourly", "daily")
)

final_step <- as.integer(experiment$nRefinementSteps)

stopifnot(
  length(final_step) == 1L,
  !is.na(final_step),
  final_step >= 0L
)

selected_step <- if (is.null(requested_step)) {
  final_step
} else {
  requested_step
}

if (selected_step > final_step) {
  stop("Requested step exceeds configured final step")
}

zDecision <- as.character(experiment$zDecision)

hydro_root <- file.path(
  experiment_dir,
  "hydrographs",
  paste0("zDecision_", zDecision)
)

if (!dir.exists(hydro_root)) {
  stop("No archived hydrographs under: ", hydro_root)
}

sim_files <- sort(list.files(
  hydro_root,
  pattern = "^qSim_selected\\.rds$",
  recursive = TRUE,
  full.names = TRUE
))

if (!length(sim_files)) {
  stop("No archived FUSE simulations under: ", hydro_root)
}

selected <- character()
selected_emulators <- character()
has_emulator <- FALSE
has_localcalib <- FALSE

# ==================================================
# 1. Discover and validate archived simulations
# ==================================================

for (sim_file in sim_files) {

  hydro_dir <- normalizePath(dirname(sim_file))

  meta_file <- file.path(hydro_dir, "metadata.rds")

  if (!file.exists(meta_file)) {
    stop("Missing simulation metadata: ", hydro_dir)
  }

  meta <- readRDS(meta_file)

  stopifnot(
    all(c(
      "experiment_dir", "config_file",
      "basinID", "zDecision"
    ) %in% names(meta))
  )

  if (
    !identical(
      normalizePath(meta$experiment_dir, mustWork = TRUE),
      experiment_dir
    ) ||
    !identical(
      normalizePath(meta$config_file, mustWork = TRUE),
      config_file
    ) ||
    !identical(as.character(meta$zDecision), zDecision)
  ) {
    stop("Simulation metadata mismatch: ", hydro_dir)
  }

  method_type <- if (is.null(meta$method_type)) {
    "emulator"
  } else {
    meta$method_type
  }

  if (identical(method_type, "emulator")) {

    has_emulator <- TRUE

    method <- if (is.null(meta$method)) {
      meta$emulator
    } else {
      meta$method
    }

    stopifnot(
      length(method) == 1L,
      method %in% experiment$emulators,
      meta$phase %in% c("train", "test"),
      length(meta$modelStep) == 1L,
      is.finite(meta$modelStep)
    )

    expected_dir <- file.path(
      hydro_root,
      meta$phase,
      as.character(meta$basinID),
      paste0("step_", meta$modelStep),
      method
    )

    if (!identical(
      hydro_dir,
      normalizePath(expected_dir, mustWork = TRUE)
    )) {
      stop("Unexpected emulator archive location: ", hydro_dir)
    }

    # Only spatial test basins, at the requested model step.
    if (
      meta$phase != "test" ||
      meta$modelStep != selected_step
    ) {
      next
    }

    selected <- c(selected, hydro_dir)

    selected_emulators <- c(
      selected_emulators,
      paste(as.character(meta$basinID), method, sep = "::")
    )

  } else if (identical(method_type, "localcalib")) {

    has_localcalib <- TRUE

    if (!is.null(requested_step)) {
      stop("--step does not apply to localcalib")
    }

    if (!identical(meta$method, "sce")) {
      stop("Unsupported local calibration method")
    }

    expected_dir <- file.path(
      hydro_root,
      as.character(meta$basinID),
      "sce"
    )

    if (!identical(
      hydro_dir,
      normalizePath(expected_dir, mustWork = TRUE)
    )) {
      stop("Unexpected local calibration location: ", hydro_dir)
    }

    selected <- c(selected, hydro_dir)

  } else {
    stop("Unknown method_type: ", method_type)
  }
}

if (anyDuplicated(selected)) {
  stop("Duplicate selected simulation directories")
}

# ==================================================
# 2. Report emulator coverage
# ==================================================

if (has_emulator) {

  test_file <- file.path(experiment_dir, "test_basins.txt")

  if (!file.exists(test_file)) {
    stop("Missing test basin list: ", test_file)
  }

  test_ids <- read_basin_ids(test_file)

  stopifnot(
    length(test_ids) > 0L,
    !anyDuplicated(test_ids),
    !anyDuplicated(selected_emulators)
  )

  expected <- as.vector(outer(
    test_ids,
    experiment$emulators,
    paste,
    sep = "::"
  ))

  unexpected <- setdiff(selected_emulators, expected)

  if (length(unexpected)) {
    stop(
      "Archived test simulations outside expected partition: ",
      paste(unexpected, collapse = ", ")
    )
  }

  missing <- setdiff(expected, selected_emulators)

  cat("\n===== EMULATOR COVERAGE =====\n")
  cat("Selected step:", selected_step, "\n")
  cat("Expected simulations:", length(expected), "\n")
  cat("Available simulations:", length(selected_emulators), "\n")
  cat("Missing simulations:", length(missing), "\n")

  if (length(missing)) {
    cat(
      "First missing combinations:",
      paste(head(missing, 10L), collapse = ", "),
      "\n"
    )
  }
}

if (has_localcalib) {
  cat("\nLocal calibration archives detected: sce\n")
}

if (!length(selected)) {
  stop(
    "No archived simulations match the requested selection. ",
    "Missing simulations were not generated."
  )
}

# ==================================================
# 3. Evaluate selected simulations
# ==================================================

evaluator <- file.path(
  dirMain,
  "scripts/05_evaluation/01_evaluate_FUSE.R"
)

expected_files <- c(
  "global_native.csv",
  "flood_native.csv",
  "metadata.rds"
)

if (experiment$timestep == "hourly") {
  expected_files <- c(
    expected_files,
    "global_daily.csv",
    "flood_daily.csv"
  )
}

n_evaluated <- 0L
n_skipped <- 0L

cat("\n===== EXPERIMENT EVALUATION =====\n")
cat("Experiment:", experiment_dir, "\n")
cat(
  "Selection:",
  if (is.null(requested_step)) "best" else paste("step", selected_step),
  "\n"
)
cat("Simulations selected:", length(selected), "\n")

for (hydro_dir in sort(selected)) {

  relative <- substring(
    hydro_dir,
    nchar(file.path(experiment_dir, "hydrographs")) + 2L
  )

  out_dir <- file.path(
    experiment_dir,
    "evaluation",
    relative
  )

  # A completed evaluation is preserved by default.
  # Incomplete directories require explicit investigation.
  if (!check_only && !force && dir.exists(out_dir)) {

    existing <- list.files(
      out_dir,
      all.files = TRUE,
      no.. = TRUE
    )

    if (length(existing)) {

      if (!setequal(existing, expected_files)) {
        stop("Incomplete or unexpected evaluation: ", out_dir)
      }

      saved <- readRDS(file.path(out_dir, "metadata.rds"))
      source_meta <- readRDS(
        file.path(hydro_dir, "metadata.rds")
      )

      saved_type <- if (is.null(saved$method_type)) {
        "emulator"
      } else {
        saved$method_type
      }

      source_type <- if (is.null(source_meta$method_type)) {
        "emulator"
      } else {
        source_meta$method_type
      }

      saved_method <- if (is.null(saved$method)) {
        saved$emulator
      } else {
        saved$method
      }

      source_method <- if (is.null(source_meta$method)) {
        source_meta$emulator
      } else {
        source_meta$method
      }

      # Never silently reuse evaluations with an older or unknown
      # temporal convention. Existing files remain untouched.
      if (!identical(
        saved$metric_period_rule,
        "complete_calendar_days_v1"
      )) {
        stop(
          "Existing evaluation uses a legacy or unknown ",
          "temporal convention: ", out_dir,
          "\nExisting results preserved. ",
          "Review before using --force."
        )
      }

      consistent <- (
        identical(saved$experiment_dir, source_meta$experiment_dir) &&
        identical(saved$config_file, source_meta$config_file) &&
        identical(saved$timestep, experiment$timestep) &&
        identical(as.character(saved$basinID),
                  as.character(source_meta$basinID)) &&
        identical(as.character(saved$zDecision),
                  as.character(source_meta$zDecision)) &&
        identical(saved_type, source_type) &&
        identical(saved_method, source_method) &&
        identical(saved$modelStep, source_meta$modelStep) &&
        identical(saved$phase, source_meta$phase) &&
        identical(saved$simulation_file,
                  file.path(hydro_dir, "qSim_selected.rds")) &&
        identical(saved$simulation_metadata_file,
                  file.path(hydro_dir, "metadata.rds"))
      )

      if (!isTRUE(consistent)) {
        stop("Existing evaluation metadata mismatch: ", out_dir)
      }

      cat("SKIP existing:", relative, "\n")
      n_skipped <- n_skipped + 1L
      next
    }
  }

  run_args <- c(
    evaluator,
    hydro_dir,
    dirMain,
    if (check_only) "--check" else if (force) "--force"
  )

  cat("\nEVALUATE:", relative, "\n")

  status <- system2(
    file.path(R.home("bin"), "Rscript"),
    args = shQuote(run_args),
    stdout = "",
    stderr = ""
  )

  if (!identical(as.integer(status), 0L)) {
    stop("Evaluation failed: ", hydro_dir)
  }

  n_evaluated <- n_evaluated + 1L
}

cat("\n===== SUMMARY =====\n")
cat("Evaluated:", n_evaluated, "\n")
cat("Skipped existing:", n_skipped, "\n")
cat("Missing archives were not generated.\n")
cat("EXPERIMENT EVALUATION COMPLETE\n")
