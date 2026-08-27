# ==============================================================================
# Workflow configuration
#
# Load config/experiment.R in its own environment and return the experiment list
# used throughout the preparation, emulator and experiment scripts.
# ==============================================================================

load_workflow_config <- function(dirMain) {
  
  cfg <- file.path(dirMain, "config", "experiment.R")
  
  if (!file.exists(cfg)) {
    stop("Missing configuration file: ", cfg)
  }
  
  env <- new.env(parent = globalenv())
  sys.source(cfg, envir = env)
  
  if (!exists("experiment", envir = env, inherits = FALSE)) {
    stop("experiment object missing from ", cfg)
  }
  
  env$experiment
}

# ==============================================================================
# Time-step information
#
# Centralize all quantities that depend on the temporal resolution so the rest
# of the workflow can remain identical for daily and hourly simulations.
# ==============================================================================

get_timestep_info <- function(experiment) {
  
  if (experiment$timestep == "daily") {
    
    list(timestep = "daily", time_units = "days", hydro_units = "mm/day", seconds_per_timestep = 86400, time_format = "%Y-%m-%d")
    
  } else if (experiment$timestep == "hourly") {
    
    list(timestep = "hourly", time_units = "hours", hydro_units = "mm/hour", seconds_per_timestep = 3600, time_format = "%Y-%m-%d %H:%M:%S")
    
  } else {
    
    stop("Unknown timestep: ", experiment$timestep, ". Expected 'daily' or 'hourly'.")
  }
}

# ==============================================================================
# Convert a NetCDF time coordinate to POSIXct
#
# The NetCDF time unit is checked against the temporal resolution defined in
# experiment.R before converting the numerical coordinate to timestamps.
# ==============================================================================

nc_time_to_posixct <- function(time_raw, units, experiment) {
  
  time_info <- get_timestep_info(experiment)
  
  time_unit <- sub(" since.*$", "", units)
  origin_string <- sub("^[^ ]+ since ", "", units)
  
  if (time_unit != time_info$time_units) {
    stop("NetCDF time unit '", time_unit, "' does not match configured time unit '",time_info$time_units, "'.")
  }
  
  origin <- as.POSIXct(origin_string, tz = experiment$timezone)
  
  origin + time_raw * time_info$seconds_per_timestep
}

# ==============================================================================
# Load one R object from an RData file
# ==============================================================================

load_rdata_single <- function(file) {
  
  if (!file.exists(file)) {
    stop("Missing RData file: ", file)
  }
  
  e <- new.env(parent = emptyenv())
  nm <- load(file, envir = e)
  
  if (length(nm) != 1L) {
    stop("Expected exactly one object in ", file, "; found: ", paste(nm, collapse = ", "))
  }
  
  e[[nm]]
}


# ==============================================================================
# Create a directory when needed
# ==============================================================================

ensure_dir <- function(path) {
  
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  
  if (!dir.exists(path)) {
    stop("Could not create directory: ", path)
  }
  
  invisible(path)
}


# ==============================================================================
# Calibration and evaluation periods used for hydrological performance metrics
# ==============================================================================

metric_periods_from_config <- function(experiment) {
  
  list(
    calibration = list(ti = experiment$calibration_start, tf = experiment$calibration_end),
    evaluation = list(ti = experiment$evaluation_start, tf = experiment$evaluation_end)
  )
}


# Normalized KGE used as the emulator target.
nkge <- function(kge) {
  kge / (2 - kge)
}


# ==============================================================================
# Standard project directories
# ==============================================================================

project_paths <- function(dirMain) {
  
  list(
    config = file.path(dirMain, "config"),
    forcings = file.path(dirMain, "data", "forcings"),
    settings = file.path(dirMain, "data", "settings"),
    decisions = file.path(dirMain, "data", "zDecisions"),
    useful = file.path(dirMain, "data", "useful_files"),
    iter0 = file.path(dirMain, "outputs", "iter0"),
    experiments = file.path(dirMain, "experiments")
  )
}
