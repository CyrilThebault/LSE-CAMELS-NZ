#!/usr/bin/env Rscript

# ==============================================================================
# Validate the CAMELS-NZ preparation used by the emulator workflow
#
# This script checks that every configured basin has the required FUSE forcing
# files, elevation-band file and static attributes. It also reports missing
# streamflow observations and checks the emulator attributes for missing values.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (
  length(args) < 2L ||
  length(args) > 3L ||
  (length(args) == 3L && !args[3] %in% c("--check", "--force"))
) {
  stop("Usage: Rscript 05_validate_preparation.R <config_file> <dirMain> [--check|--force]")
}

check <- length(args) == 3L && args[3] == "--check"
force <- length(args) == 3L && args[3] == "--force"

config_file <- normalizePath(args[1], mustWork = TRUE)
dirMain <- normalizePath(args[2], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(config_file)
time_info <- get_timestep_info(experiment)
paths <- project_paths(dirMain, experiment)

attribute_qc_file <- file.path(paths$useful, "attribute_QC.csv")
basin_qc_file <- file.path(paths$useful, "basin_attribute_QC.csv")
report_file <- file.path(paths$preparation, "preparation_report.csv")

if (!check && !force) {
  output_files <- c(attribute_qc_file, basin_qc_file, report_file)
  existing_files <- output_files[file.exists(output_files)]

  if (length(existing_files) > 0L) {
    stop(
      "Preparation report(s) already exist:\n",
      paste(existing_files, collapse = "\n"),
      "\nUse --check for read-only validation or --force to replace reports."
    )
  }
}

suppressPackageStartupMessages(library(ncdf4))

basins <- read_basin_ids(file.path(dirMain, "config", "basins.txt"))
attributes <- load_rdata_single(file.path(paths$useful, "attributes.RData"))

# Attributes must contain exactly the configured basins, in the same order.
if (!"ID" %in% names(attributes)) {
  stop("ID column missing from attributes.RData")
}

attribute_ids <- as.character(attributes$ID)

if (!identical(attribute_ids, as.character(basins))) {
  missing <- setdiff(basins, attribute_ids)
  extra <- setdiff(attribute_ids, basins)

  stop(
    "attributes.RData does not match config/basins.txt.",
    "\nMissing basins: ",
    if (length(missing)) paste(missing, collapse = ", ") else "none",
    "\nExtra basins: ",
    if (length(extra)) paste(extra, collapse = ", ") else "none",
    "\nThe basin order must also match."
  )
}


# ==============================================================================
# Basin-level preparation checks
# ==============================================================================

# FUSE forcing timestamps are stored at the midpoint of each interval.
# The expected axis is derived entirely from the experiment configuration.
expected_time <- seq.POSIXt(
  from = experiment$simulation_start,
  to = experiment$simulation_end,
  by = time_info$seconds_per_timestep
) + time_info$seconds_per_timestep / 2

rows <- lapply(basins, function(id) {
  
  input <- file.path(paths$forcings, id, paste0(id, "_input.nc"))
  elev <- file.path(paths$forcings, id, paste0(id, "_elev_bands.nc"))
  
  has_att <- sum(as.character(attributes$ID) == id) == 1L
  ok_input <- file.exists(input)
  
  time_unit_valid <- NA
  time_axis_valid <- NA
  n_timesteps <- NA_integer_
  q_missing <- NA_real_
  forcing_na <- NA
  
  if (ok_input) {
    
    nc <- nc_open(input)
    
    t <- ncvar_get(nc, "time")
    
    time_units <- ncatt_get(nc, "time", "units")$value
    netcdf_time_unit <- sub(" since.*$", "", time_units)
    
    time_unit_valid <- identical(netcdf_time_unit, time_info$time_units)

    time_axis_valid <- FALSE

    if (
      isTRUE(time_unit_valid) &&
      length(t) == length(expected_time) &&
      all(is.finite(t))
    ) {
      actual_time <- nc_time_to_posixct(t, time_units, experiment)

      time_axis_valid <- all(is.finite(as.numeric(actual_time))) &&
        all(
          abs(as.numeric(actual_time) - as.numeric(expected_time)) < 1e-4
        )
    }
    
    q <- ncvar_get(nc, "q_obs")
    
    n_timesteps <- length(t)
    q_missing <- mean(is.na(q) | q < 0) * 100
    
    forcing_na <- any(
      vapply(c("pr", "temp", "pet"), function(v) anyNA(ncvar_get(nc, v)), logical(1))
    )
    
    nc_close(nc)
  }
  
  data.frame(
    ID = id,
    input = ok_input,
    elev = file.exists(elev),
    attributes = has_att,
    n_timesteps = n_timesteps,
    time_unit_valid = time_unit_valid,
    time_axis_valid = time_axis_valid,
    qobs_missing_pct = q_missing,
    forcing_has_NA = forcing_na,
    valid = ok_input && file.exists(elev) && has_att &&
      isTRUE(time_unit_valid) && isTRUE(time_axis_valid) &&
      isFALSE(forcing_na)
  )
})


# ==============================================================================
# Static-attribute quality control
#
# Only the attributes configured for the emulator are checked here. Missing
# values should be resolved before the training stage rather than silently
# propagating into the regionalisation experiments.
# ==============================================================================

configured_attributes <- readLines(file.path(dirMain, "config", "attributes_used.txt"), warn = FALSE)
configured_attributes <- configured_attributes[nzchar(trimws(configured_attributes))]

missing_columns <- setdiff(configured_attributes, names(attributes))

if (length(missing_columns)) {
  stop("Configured attributes missing from attributes.RData: ",
       paste(missing_columns, collapse = ", "))
}

attribute_data <- attributes[, configured_attributes, drop = FALSE]

attribute_qc <- data.frame(
  attribute = configured_attributes,
  type = vapply(attribute_data, function(x) class(x)[1], character(1)),
  n_missing = vapply(attribute_data, function(x) sum(is.na(x)), integer(1)),
  pct_missing = vapply(attribute_data, function(x) mean(is.na(x)) * 100, numeric(1)),
  n_unique = vapply(attribute_data, function(x) length(unique(na.omit(x))), integer(1))
)

# ==============================================================================
# Missing attributes by basin
# ==============================================================================

basin_attribute_qc <- data.frame(
  ID = as.character(attributes$ID),
  n_missing_attributes = rowSums(is.na(attribute_data))
)

# ==============================================================================
# Final preparation report
# ==============================================================================

report <- do.call(rbind, rows)

if (!check) {
  ensure_dir(paths$useful)
  ensure_dir(paths$preparation)

  write.csv(attribute_qc, attribute_qc_file, row.names = FALSE)
  write.csv(basin_attribute_qc, basin_qc_file, row.names = FALSE)
  write.csv(report, report_file, row.names = FALSE)
} else {
  message("Read-only preparation check: no reports written.")
}

print(report)

if (!all(report$valid)) {
  stop("Preparation validation failed for ", sum(!report$valid), " basin(s)")
}