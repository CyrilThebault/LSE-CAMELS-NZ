# ==============================================================================
# Workflow configuration
#
# One campaign configuration, explicitly resolved to daily or hourly.
# The planner can also request the unresolved campaign.
# ==============================================================================

load_workflow_config <- function(
  config_file,
  timestep = NULL,
  mode = c("execution", "campaign")
) {

  mode <- match.arg(mode)
  config_file <- normalizePath(config_file, mustWork = TRUE)

  env <- new.env(parent = globalenv())
  sys.source(config_file, envir = env)

  if (!exists("experiment", envir = env, inherits = FALSE)) {
    stop("experiment object missing from ", config_file)
  }

  experiment <- env$experiment

  if (!is.list(experiment)) {
    stop("experiment must be a list: ", config_file)
  }

  available <- experiment$timesteps

  if (!is.character(available) ||
      length(available) == 0L ||
      anyNA(available) ||
      anyDuplicated(available) ||
      !all(available %in% c("daily", "hourly"))) {
    stop("Invalid unified campaign timesteps: ", config_file)
  }

  if (identical(mode, "campaign")) {
    if (!is.null(timestep)) {
      stop("Campaign mode does not accept a timestep")
    }
    return(experiment)
  }

  if (!is.character(timestep) ||
      length(timestep) != 1L ||
      is.na(timestep) ||
      !timestep %in% c("daily", "hourly")) {
    stop("Execution requires timestep = 'daily' or 'hourly'")
  }

  if (!timestep %in% available) {
    stop("Timestep not available in campaign: ", timestep)
  }

  resolve_workflow_config(experiment, timestep)
}


# ==============================================================================
# Canonical observed flood workflow configuration
#
# The observed flood catalogue uses hourly Qobs independently of the
# resolution selected for a daily/hourly simulation.
# ==============================================================================

load_observed_flood_config <- function(config_file) {
  load_workflow_config(config_file, timestep = "hourly")
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
# experiment configuration before converting the numerical coordinate to timestamps.
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

project_paths <- function(dirMain, experiment) {
  
  timestep <- experiment$timestep
  
  list(
    config = file.path(dirMain, "config"),
    forcings = file.path(dirMain, "data", "forcings", timestep),
    settings = file.path(dirMain, "data", "settings"),
    decisions = file.path(dirMain, "data", "zDecisions"),
    useful = file.path(dirMain, "data", "useful_files"),
    preparation = file.path(dirMain, "data", "useful_files", timestep),
    iter0 = file.path(dirMain, "outputs", timestep, "iter0"),
    experiments = file.path(dirMain, "experiments", timestep)
  )
}


# ==============================================================================
# Resolve a unified campaign configuration for one timestep
#
# The campaign defines all permitted timesteps.
# Existing scientific functions continue to receive a scalar timestep.
#
# The final time boundaries preserve the historical daily/hourly conventions.
# ==============================================================================

resolve_workflow_config <- function(campaign, timestep) {

  if (!is.list(campaign) ||
      !"timesteps" %in% names(campaign) ||
      "timestep" %in% names(campaign)) {
    stop("Expected an unresolved unified campaign configuration")
  }

  allowed <- campaign$timesteps

  if (!is.character(allowed) ||
      length(allowed) == 0L ||
      anyNA(allowed) ||
      any(!nzchar(allowed)) ||
      anyDuplicated(allowed) ||
      any(!allowed %in% c("daily", "hourly"))) {
    stop("Invalid configured timesteps")
  }

  if (!is.character(timestep) ||
      length(timestep) != 1L ||
      is.na(timestep) ||
      !timestep %in% allowed) {
    stop(
      "Invalid timestep selection. Configured: ",
      paste(allowed, collapse = ", ")
    )
  }

  resolved <- campaign

  names(resolved)[
    names(resolved) == "timesteps"
  ] <- "timestep"

  resolved$timestep <- timestep

  if (timestep == "hourly") {

    for (field in c(
      "simulation_end",
      "calibration_end",
      "evaluation_end"
    )) {

      resolved[[field]] <- resolved[[field]] + 23 * 3600
    }
  }

  resolved
}
