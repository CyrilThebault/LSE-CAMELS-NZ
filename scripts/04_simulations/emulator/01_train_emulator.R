#!/usr/bin/env Rscript

# ==============================================================================
# Train a Large-Sample Emulator for one experiment fold and one iteration
#
# The emulator is trained only with the basins listed in train_basins.txt.
# Static catchment attributes are taken from the CAMELS-NZ attribute database.
#
# Categorical levels are defined from the complete CAMELS-NZ dataset rather than
# from the training fold alone. This allows a held-out catchment to contain a
# valid category that is absent from the training basins.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- paste(
  "Usage: Rscript 01_train_emulator.R",
  "<experiment_dir> <zDecision> <iStep> <nCores> <config_file> <dirMain>",
  "--timestep <daily|hourly> [--emulator RF,GBMv02] [--resume]"
)

if (length(args) < 8L || !identical(args[7L], "--timestep")) {
  stop(usage)
}

workflow_timestep <- args[8L]

if (!(workflow_timestep %in% c("daily", "hourly"))) {
  stop("Invalid --timestep: ", workflow_timestep, ". Expected daily or hourly")
}

experiment_dir <- normalizePath(args[1], mustWork = TRUE)
zDecision <- args[2]
iStep <- as.integer(args[3])
nCores <- as.integer(args[4])
config_file <- normalizePath(args[5], mustWork = TRUE)
dirMain <- normalizePath(args[6], mustWork = TRUE)


# ==============================================================================
# Functions and packages
# ==============================================================================

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/emulator_data.R"))
source(file.path(dirMain, "scripts/functions/emulator.R"))

suppressPackageStartupMessages({
  library(ranger)
  library(xgboost)
  library(Matrix)
})


# ==============================================================================
# Configuration and input data
# ==============================================================================

experiment <- load_workflow_config(
  config_file,
  timestep = workflow_timestep
)

# Select methods without modifying the campaign configuration.
optional_args <- if (length(args) > 8L) args[-seq_len(8L)] else character()

resume <- "--resume" %in% optional_args

if (sum(optional_args == "--resume") > 1L) {
  stop("Duplicate --resume option")
}

optional_args <- optional_args[optional_args != "--resume"]

emulator_value <- NULL

if (length(optional_args)) {
  if (length(optional_args) != 2L ||
      !identical(optional_args[1L], "--emulator") ||
      !nzchar(optional_args[2L])) {
    stop("Expected --emulator followed by comma-separated methods")
  }
  emulator_value <- optional_args[2L]
}

selected_emulators <- if (is.null(emulator_value)) {
  experiment$emulators
} else {
  if (grepl(",[[:space:]]*$", emulator_value)) {
    stop("Invalid --emulator list: trailing comma")
  }
  trimws(strsplit(emulator_value, ",", fixed = TRUE)[[1L]])
}

if (!length(selected_emulators) ||
    anyNA(selected_emulators) ||
    any(!nzchar(selected_emulators)) ||
    anyDuplicated(selected_emulators) ||
    any(!selected_emulators %in% experiment$emulators)) {
  stop("Invalid or duplicate emulator selection")
}

paths <- project_paths(dirMain, experiment)

train_ids <- read_basin_ids(file.path(experiment_dir, "train_basins.txt"))
attributes <- load_rdata_single(file.path(paths$useful, "attributes.RData"))
meta <- load_rdata_single(file.path(paths$useful, "fuse_settings_files.RData"))
info <- get_parameter_info(meta, zDecision)


# ==============================================================================
# Attributes used by the emulator
# ==============================================================================

attribute_names <- readLines(file.path(dirMain, "config", "attributes_used.txt"), warn = FALSE)
attribute_names <- trimws(attribute_names)
attribute_names <- attribute_names[nzchar(attribute_names)]

missing_cols <- setdiff(attribute_names, names(attributes))

if (length(missing_cols) > 0L) {
  stop("Configured attributes missing from attributes.RData: ", paste(missing_cols, collapse = ", "))
}


# ==============================================================================
# Identify categorical attributes from the complete CAMELS-NZ dataset
#
# Character, factor and logical attributes are treated as categorical. Numeric
# attributes that contain only integer values and a limited number of classes
# are also treated as categorical, for example Stream_Order.
#
# Levels are defined globally so that a category absent from one training fold
# is still recognised when predicting a held-out catchment.
# ==============================================================================

attributes_used <- attributes[, attribute_names, drop = FALSE]

categorical_attributes <- names(attributes_used)[
  vapply(
    attributes_used,
    function(x) is.character(x) || is.factor(x) || is.logical(x) || is_integer_categorical(x),
    logical(1)
  )
]

categorical_levels <- lapply(
  attributes_used[, categorical_attributes, drop = FALSE],
  function(x) sort(unique(as.character(x[!is.na(x)])))
)

if (length(categorical_attributes) > 0L) {
  message("Categorical attributes defined from CAMELS-NZ: ",
          paste(categorical_attributes, collapse = ", "))
}


# ==============================================================================
# Remove attributes that are constant within the current training fold
#
# A constant attribute cannot contribute to the emulator for this fold and is
# removed before training. Its global category definition remains unchanged.
# ==============================================================================

rows_train <- match(train_ids, as.character(attributes$ID))

if (anyNA(rows_train)) {
  missing_ids <- train_ids[is.na(rows_train)]
  stop("Training basin(s) missing from attributes.RData: ", paste(missing_ids, collapse = ", "))
}

att_train <- attributes[rows_train, attribute_names, drop = FALSE]

nunique <- vapply(att_train, function(x) length(unique(na.omit(x))), integer(1))
constant_attributes <- attribute_names[nunique < 2L]

if (length(constant_attributes) > 0L) {
  message("Attributes constant in this training fold and removed: ",
          paste(constant_attributes, collapse = ", "))
}

attribute_names <- attribute_names[nunique >= 2L]
att_train <- attributes[rows_train, attribute_names, drop = FALSE]


# ==============================================================================
# Check missing static attributes
#
# Missing attributes should be resolved during preparation rather than silently
# propagating into emulator training.
# ==============================================================================

if (anyNA(att_train)) {
  
  missing_by_attribute <- names(att_train)[vapply(att_train, anyNA, logical(1))]
  
  stop(
    "Missing static attributes remain in training basins: ",
    paste(missing_by_attribute, collapse = ", "),
    ". Resolve or impute them before model training."
  )
}


# ==============================================================================
# Keep only categorical levels used by the current emulator
# ==============================================================================

categorical_levels <- categorical_levels[
  intersect(names(categorical_levels), attribute_names)
]


# ==============================================================================
# Output directory
# ==============================================================================

model_dir <- ensure_dir(
  file.path(experiment_dir, "outputs", paste0("zDecision_", zDecision), "models")
)


# ==============================================================================
# Train emulators
# ==============================================================================

# Refuse to overwrite models from an existing training step.
# Check all selected emulators before starting any training.


resume_model_status <- function(
  path, method, step, zDecision, train_ids, seed
) {

  link <- Sys.readlink(path)

  if (!is.na(link) && nzchar(link)) return("STOP")
  if (dir.exists(path)) return("STOP")
  if (!file.exists(path)) return("RUN")

  env <- new.env(parent = baseenv())

  loaded <- tryCatch(
    withCallingHandlers(
      load(path, envir = env),
      warning = function(w) {
        stop(conditionMessage(w))
      }
    ),
    error = function(e) NULL
  )

  if (!identical(loaded, "summary")) return("STOP")

  s <- env$summary

  if (!is.list(s)) return("STOP")

  provenance_ok <- (
    identical(as.character(s$model_type), method) &&
    identical(as.character(s$zDecision), as.character(zDecision)) &&
    identical(as.character(s$step), as.character(step)) &&
    identical(as.character(s$seed), as.character(seed)) &&
    identical(as.character(s$training_basins), as.character(train_ids))
  )

  preprocessing_ok <- (
    is.list(s$preprocessing) &&
    all(c(
      "parameter_names",
      "attribute_names",
      "design_columns"
    ) %in% names(s$preprocessing))
  )

  model_ok <- if (method == "RF") {
    inherits(s$model, "ranger") &&
      !is.null(s$model$forest)
  } else if (method %in% c("GBMv01", "GBMv02")) {
    inherits(s$model, "xgb.Booster") &&
      length(s$model) > 0L
  } else {
    FALSE
  }

  if (!provenance_ok || !preprocessing_ok || !model_ok) {
    return("STOP")
  }

  "SKIP"
}


model_files <- file.path(
  model_dir,
  paste0("emulator_step_", iStep, "_", selected_emulators, ".RData")
)

existing_models <- model_files[file.exists(model_files)]

if (!resume && length(existing_models) > 0L) {
  stop(
    "Emulator model output(s) already exist:\n",
    paste(existing_models, collapse = "\n"),
    "\nRefusing to overwrite existing models."
  )
}

methods_to_train <- selected_emulators

if (resume) {

  states <- setNames(
    vapply(seq_along(selected_emulators), function(i) {
      resume_model_status(
        path = model_files[i],
        method = selected_emulators[i],
        step = iStep,
        zDecision = zDecision,
        train_ids = train_ids,
        seed = experiment$seed
      )
    }, character(1L)),
    selected_emulators
  )

  for (ml in names(states)) {
    message("RESUME ", ml, ": ", states[[ml]])
  }

  if (any(states == "STOP")) {
    stop(
      "Resume refused: invalid existing model(s): ",
      paste(names(states)[states == "STOP"], collapse = ", ")
    )
  }

  methods_to_train <- names(states)[states == "RUN"]
}

for (ml in methods_to_train) {
  
  message("")
  message("============================================================")
  message("Training ", ml)
  message("zDecision: ", zDecision)
  message("Iteration: ", iStep)
  message("Training basins: ", length(train_ids))
  message("Catchment attributes: ", length(attribute_names))
  message("============================================================")
  
  # Build the emulator database from iter0 and, when applicable, parameter sets
  # evaluated during previous refinement steps.
  dat <- build_emulator_dataset(
    paths, experiment_dir, train_ids, zDecision, iStep, ml,
    attributes, attribute_names, info$names, experiment$nCandidates
  )
  
  message("Training observations: ", nrow(dat))
  
  # Train the emulator using the globally defined categorical feature space.
  summary <- train_one_emulator(
    emulator_type = ml,
    emulatorData = dat,
    parameter_names = info$names,
    attribute_names = attribute_names,
    categorical_levels = categorical_levels,
    experiment = experiment,
    nCores = nCores
  )
  
  # Save the fold and iteration metadata with the trained emulator.
  summary$zDecision <- zDecision
  summary$step <- iStep
  summary$training_basins <- train_ids
  summary$seed <- experiment$seed
  
  file_out <- file.path(model_dir, paste0("emulator_step_", iStep, "_", ml, ".RData"))
  
  save(summary, file = file_out)
  
  message("Saved emulator: ", file_out)
}
