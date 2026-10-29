#!/usr/bin/env Rscript

# Local FUSE calibration with SCE.
#
# archive: validate and archive an existing SCE + OPT workspace.
# run:     prepare a new workspace, execute SCE + OPT, then archive.
#
# No global timeout for SCE.
# Existing calibration results are never overwritten.

main <- function() {

  args <- commandArgs(trailingOnly = TRUE)

  if (length(args) != 8L || !identical(args[7L], "--timestep")) {
    stop(
      "Usage: Rscript 01_run_local_calibration.R ",
      "<basinID> <experiment_dir> ",
      "<archive|run> <work_dir> <config_file> <dirMain> ",
      "--timestep <daily|hourly>"
    )
  }

  workflow_timestep <- args[8L]

  if (!(workflow_timestep %in% c("daily", "hourly"))) {
    stop(
      "Invalid --timestep: ", workflow_timestep,
      ". Expected daily or hourly"
    )
  }

  basinID <- as.character(args[1])
  experiment_dir <- normalizePath(args[2], mustWork = FALSE)
  action <- args[3]
  work_dir <- normalizePath(args[4], mustWork = FALSE)
  config_file <- normalizePath(args[5], mustWork = TRUE)
  dirMain <- normalizePath(args[6], mustWork = TRUE)

  stopifnot(
    nzchar(basinID),
    action %in% c("archive", "run")
  )

  source(file.path(dirMain, "scripts/functions/common.R"))
  source(file.path(dirMain, "scripts/functions/fuse.R"))

  experiment <- load_workflow_config(
    config_file,
    timestep = workflow_timestep
  )
  time_info <- get_timestep_info(experiment)

  zDecision <- as.character(experiment$zDecision)

  stopifnot(
    experiment$timestep %in% c("hourly", "daily"),
    length(zDecision) == 1L,
    !is.na(zDecision),
    nzchar(zDecision)
  )

  raw_dir <- file.path(
    experiment_dir, "outputs",
    paste0("zDecision_", zDecision),
    basinID, "sce"
  )

  hydro_dir <- file.path(
    experiment_dir, "hydrographs",
    paste0("zDecision_", zDecision),
    basinID, "sce"
  )

  # Protect both persistent destinations before doing any work.
  if (file.exists(raw_dir) || dir.exists(raw_dir) ||
      file.exists(hydro_dir) || dir.exists(hydro_dir)) {
    stop(
      "Existing local calibration results. Refusing overwrite:\n",
      raw_dir, "\n", hydro_dir
    )
  }

  control_file <- file.path(
    work_dir, "settings", "fuse_control",
    paste0("fuse_control_", basinID, "_", zDecision, ".toml")
  )

  output_dir <- file.path(work_dir, "output")
  prefix <- paste0(basinID, "_", zDecision, "__")

  sce_params <- file.path(output_dir, paste0(prefix, "para_sce.nc"))
  opt_params <- file.path(output_dir, paste0(prefix, "para_opt.nc"))
  opt_runs <- file.path(output_dir, paste0(prefix, "runs_opt.nc"))
  sce_diag <- file.path(output_dir, paste0(prefix, "sce_output.txt"))
  sce_log <- file.path(output_dir, "sce_console.log")
  opt_log <- file.path(output_dir, "opt_console.log")

  cat("\n===== LOCAL FUSE CALIBRATION =====\n")
  cat("Basin:", basinID, "\n")
  cat("Timestep:", experiment$timestep, "\n")
  cat("zDecision:", zDecision, "\n")
  cat("Action:", action, "\n")
  cat("Workspace:", work_dir, "\n")

  # ==================================================
  # 1. Run SCE and OPT when requested
  # ==================================================

  if (action == "run") {

    if (file.exists(work_dir) || dir.exists(work_dir)) {
      stop("FUSE workspace already exists: ", work_dir)
    }

    prepare_fuse_workspace(
      dirMain = dirMain,
      work_dir = work_dir,
      basinID = basinID,
      zDecision = zDecision,
      experiment = experiment
    )

    fuse_exe <- experiment$paths$fuse_exe

    if (!file.exists(fuse_exe)) {
      stop("FUSE executable not found: ", fuse_exe)
    }

    run_fuse_mode <- function(mode, log_file, sets_file = NULL) {

      cmd_args <- c(
        "-d", shQuote(basinID),
        "-c", shQuote(control_file),
        "-m", mode
      )

      if (!is.null(sets_file)) {
        cmd_args <- c(cmd_args, "-s", shQuote(sets_file))
      }

      exit_code <- system2(
        fuse_exe,
        args = cmd_args,
        stdout = log_file,
        stderr = log_file
      )

      if (exit_code != 0L) {
        stop(
          "FUSE ", mode, " failed (exit ", exit_code,
          "). See: ", log_file
        )
      }
    }

    cat("\n===== RUN SCE =====\n")

    run_fuse_mode("sce", sce_log)

    if (!file.exists(sce_params) ||
        is.na(file.info(sce_params)$size) ||
        file.info(sce_params)$size == 0) {
      stop("SCE did not produce a valid parameter file")
    }

    # Fortran STOP may return exit code zero even after an early failure.
    # Require evidence that SCE reached its final estimate.
    sce_lines <- readLines(sce_log, warn = FALSE)

    if (!any(grepl(
      "PRINT THE FINAL PARAMETER ESTIMATE",
      sce_lines, fixed = TRUE
    ))) {
      stop("SCE did not reach its final parameter estimate")
    }

    cat("\n===== RUN OPT =====\n")

    run_fuse_mode("opt", opt_log, sce_params)
  }

  # ==================================================
  # 2. Validate the completed workspace
  # ==================================================

  if (!dir.exists(work_dir)) {
    stop("Workspace does not exist: ", work_dir)
  }

  required_files <- c(
    control_file, sce_params, opt_params, opt_runs,
    sce_diag, sce_log, opt_log
  )

  missing <- required_files[!file.exists(required_files)]

  if (length(missing)) {
    stop("Missing calibration files:\n",
         paste(missing, collapse = "\n"))
  }

  sizes <- file.info(required_files)$size

  if (any(is.na(sizes) | sizes <= 0)) {
    stop("One or more calibration files are empty")
  }

  sce_lines <- readLines(sce_log, warn = FALSE)
  opt_lines <- readLines(opt_log, warn = FALSE)

  if (!any(grepl(
    "PRINT THE FINAL PARAMETER ESTIMATE",
    sce_lines, fixed = TRUE
  ))) {
    stop("SCE completion cannot be confirmed")
  }

  if (!any(trimws(opt_lines) == "Done")) {
    stop("OPT completion cannot be confirmed")
  }

  # ==================================================
  # 3. Read the optimal FUSE simulation
  # ==================================================

  nc <- ncdf4::nc_open(opt_runs)

  time_raw <- ncdf4::ncvar_get(nc, "time")
  time_units <- ncdf4::ncatt_get(nc, "time", "units")$value

  time <- nc_time_to_posixct(
    time_raw, time_units, experiment
  )

  qsim_units <- ncdf4::ncatt_get(
    nc, "q_routed", "units"
  )$value

  if (!identical(qsim_units, "mm/day")) {
    ncdf4::nc_close(nc)
    stop("Unexpected q_routed units: ", qsim_units)
  }

  qsim_mmd <- as.numeric(
    ncdf4::ncvar_get(nc, "q_routed")
  )

  fuse_branch <- ncdf4::ncatt_get(
    nc, 0, "fuse_git_branch"
  )$value

  fuse_hash <- ncdf4::ncatt_get(
    nc, 0, "fuse_git_hash"
  )$value

  ncdf4::nc_close(nc)

  qsim_values <- qsim_mmd *
    time_info$seconds_per_timestep / 86400

  qsim <- data.frame(
    time = time,
    qSim = qsim_values
  )

  stopifnot(
    length(time) > 0L,
    length(time) == length(qsim_values),
    !anyDuplicated(time),
    all(is.finite(qsim_values)),
    all(qsim_values >= 0),
    is.character(fuse_hash),
    length(fuse_hash) == 1L,
    nzchar(fuse_hash)
  )

  if (nrow(qsim) > 1L &&
      any(abs(diff(as.numeric(time)) -
              time_info$seconds_per_timestep) > 1)) {
    stop("Irregular simulated time axis")
  }

  # Verify alignment with original observed timestamps.
  obs_file <- file.path(
    dirMain, "data", "forcings",
    experiment$timestep, basinID,
    paste0(basinID, "_input.nc")
  )

  qobs <- read_qobs(obs_file, experiment)

  if (!all(qsim$time %in% qobs$time)) {
    stop("Simulated timestamps do not match the forcing time axis")
  }

  # Read FUSE's calibration performance from OPT.
  nc <- ncdf4::nc_open(opt_params)

  opt_kge <- as.numeric(ncdf4::ncvar_get(nc, "kge"))
  opt_metric <- as.numeric(
    ncdf4::ncvar_get(nc, "metric_val")
  )

  ncdf4::nc_close(nc)

  stopifnot(
    length(opt_kge) == 1L,
    length(opt_metric) == 1L,
    is.finite(opt_kge),
    is.finite(opt_metric)
  )

  cat("\n===== VALIDATED OPTIMUM =====\n")
  cat("FUSE branch:", fuse_branch, "\n")
  cat("FUSE hash:", fuse_hash, "\n")
  cat("KGE calibration:", opt_kge, "\n")
  cat("Optimization metric:", opt_metric, "\n")
  cat("Simulated steps:", nrow(qsim), "\n")
  cat("First:", format(min(qsim$time)), "\n")
  cat("Last :", format(max(qsim$time)), "\n")

  # ==================================================
  # 4. Stage archived outputs before publication
  # ==================================================

  metadata <- list(
    experiment_dir = experiment_dir,
    config_file = config_file,
    basinID = basinID,
    zDecision = zDecision,
    method_type = "localcalib",
    method = "sce",
    timestep = experiment$timestep,
    fuse_git_branch = fuse_branch,
    fuse_git_hash = fuse_hash,
    opt_KGEc = opt_kge,
    opt_metric = opt_metric
  )

  dir.create(
    experiment_dir,
    recursive = TRUE,
    showWarnings = FALSE
  )

  stage <- tempfile(
    pattern = paste0(".sce_", basinID, "_"),
    tmpdir = experiment_dir
  )

  dir.create(stage)

  on.exit(
    unlink(stage, recursive = TRUE),
    add = TRUE
  )

  staged_raw <- file.path(stage, "outputs")
  staged_hydro <- file.path(stage, "hydrographs")

  dir.create(staged_raw)
  dir.create(staged_hydro)

  raw_sources <- c(
    sce_params, opt_params, opt_runs,
    sce_diag, sce_log, opt_log, control_file
  )

  raw_names <- c(
    basename(sce_params),
    basename(opt_params),
    basename(opt_runs),
    basename(sce_diag),
    "sce_console.log",
    "opt_console.log",
    "fuse_control.toml"
  )

  for (i in seq_along(raw_sources)) {
    if (!file.copy(
      raw_sources[i],
      file.path(staged_raw, raw_names[i]),
      overwrite = FALSE
    )) {
      stop("Failed to stage: ", raw_sources[i])
    }
  }

  saveRDS(
    qsim,
    file.path(staged_hydro, "qSim_selected.rds")
  )

  saveRDS(
    metadata,
    file.path(staged_hydro, "metadata.rds")
  )

  # ==================================================
  # 5. Publish without overwriting existing results
  # ==================================================

  if (file.exists(raw_dir) || dir.exists(raw_dir) ||
      file.exists(hydro_dir) || dir.exists(hydro_dir)) {
    stop("Calibration destination appeared during processing")
  }

  dir.create(dirname(raw_dir),
             recursive = TRUE, showWarnings = FALSE)

  dir.create(dirname(hydro_dir),
             recursive = TRUE, showWarnings = FALSE)

  if (!file.rename(staged_raw, raw_dir)) {
    stop("Could not publish calibration outputs")
  }

  if (!file.rename(staged_hydro, hydro_dir)) {
    unlink(raw_dir, recursive = TRUE)
    stop("Could not publish archived hydrograph")
  }

  cat("\n===== LOCAL CALIBRATION ARCHIVED =====\n")
  cat("Parameters and logs:", raw_dir, "\n")
  cat("Hydrograph:", hydro_dir, "\n")
  cat("Workspace retained:", work_dir, "\n")
  cat("LOCAL CALIBRATION COMPLETE\n")
}

main()
