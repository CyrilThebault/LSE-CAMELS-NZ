# Lightweight preflight validation of archived local SCE calibrations.
# Does not replace the numerical validation performed before archiving.

local_calibration_archive_status <- function(experiment_dir, basinID, zDecision) {

  raw_dir <- file.path(
    experiment_dir, "outputs",
    paste0("zDecision_", zDecision), basinID, "sce"
  )

  hydro_dir <- file.path(
    experiment_dir, "hydrographs",
    paste0("zDecision_", zDecision), basinID, "sce"
  )

  result <- function(status, reason) {
    list(status = status, reason = reason)
  }

  if (!file.exists(raw_dir) && !file.exists(hydro_dir)) {
    return(result("absent", "No archive found"))
  }

  if (!dir.exists(raw_dir) || !dir.exists(hydro_dir)) {
    return(result("incomplete", "Missing archive directory"))
  }

  prefix <- paste0(basinID, "_", zDecision, "__")

  required <- c(
    file.path(raw_dir, paste0(prefix, "para_sce.nc")),
    file.path(raw_dir, paste0(prefix, "para_opt.nc")),
    file.path(raw_dir, paste0(prefix, "runs_opt.nc")),
    file.path(raw_dir, paste0(prefix, "sce_output.txt")),
    file.path(raw_dir, "sce_console.log"),
    file.path(raw_dir, "opt_console.log"),
    file.path(raw_dir, "fuse_control.toml"),
    file.path(hydro_dir, "qSim_selected.rds"),
    file.path(hydro_dir, "metadata.rds")
  )

  sizes <- file.info(required)$size

  invalid <- !file.exists(required) |
    dir.exists(required) |
    is.na(sizes) |
    sizes <= 0

  if (any(invalid)) {
    return(result(
      "incomplete",
      paste(
        "Missing or empty files:",
        paste(basename(required[invalid]), collapse = ", ")
      )
    ))
  }

  sce_lines <- tryCatch(
    readLines(file.path(raw_dir, "sce_console.log"), warn = FALSE),
    error = function(e) NULL
  )

  opt_lines <- tryCatch(
    readLines(file.path(raw_dir, "opt_console.log"), warn = FALSE),
    error = function(e) NULL
  )

  if (is.null(sce_lines) ||
      !any(grepl(
        "PRINT THE FINAL PARAMETER ESTIMATE",
        sce_lines,
        fixed = TRUE
      ))) {
    return(result("incomplete", "SCE final estimate not confirmed"))
  }

  if (is.null(opt_lines) ||
      !any(trimws(opt_lines) == "Done")) {
    return(result("incomplete", "OPT completion not confirmed"))
  }

  result("complete", "SCE and OPT completion markers confirmed")
}
