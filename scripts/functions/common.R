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
# Replace one value in a TOML configuration file
# ==============================================================================

set_toml <- function(x, key, value, quote = TRUE) {
  
  pattern <- paste0("^\\s*", key, "\\s*=.*$")
  hit <- grepl(pattern, x)
  
  if (sum(hit) != 1L) {
    stop("Expected exactly one occurrence of TOML key: ", key)
  }
  
  x[hit] <- if (quote) {
    sprintf('%s = "%s"', key, value)
  } else {
    sprintf("%s = %s", key, value)
  }
  
  x
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