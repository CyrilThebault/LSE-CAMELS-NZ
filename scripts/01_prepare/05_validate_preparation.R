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


# ==============================================================================
# Basin-level preparation checks
# ==============================================================================

rows <- lapply(basins, function(id) {
  
  input <- file.path(paths$forcings, id, paste0(id, "_input.nc"))
  elev <- file.path(paths$forcings, id, paste0(id, "_elev_bands.nc"))
  
  has_att <- sum(as.character(attributes$ID) == id) == 1L
  ok_input <- file.exists(input)
  
  time_unit_valid <- NA
  n_timesteps <- NA_integer_
  q_missing <- NA_real_
  forcing_na <- NA
  
  if (ok_input) {
    
    nc <- nc_open(input)
    
    t <- ncvar_get(nc, "time")
    
    time_units <- ncatt_get(nc, "time", "units")$value
    netcdf_time_unit <- sub(" since.*$", "", time_units)
    
    time_unit_valid <- identical(netcdf_time_unit, time_info$time_units)
    
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
    qobs_missing_pct = q_missing,
    forcing_has_NA = forcing_na,
    valid = ok_input && file.exists(elev) && has_att && isTRUE(time_unit_valid) && isFALSE(forcing_na)
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