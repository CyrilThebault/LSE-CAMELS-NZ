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

if (length(args) != 5L) {
  stop("Usage: Rscript 01_train_emulator.R <experiment_dir> <zDecision> <iStep> <nCores> <dirMain>")
}

experiment_dir <- normalizePath(args[1], mustWork = TRUE)
zDecision <- args[2]
iStep <- as.integer(args[3])
nCores <- as.integer(args[4])
dirMain <- normalizePath(args[5], mustWork = TRUE)


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

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain)

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

for (ml in experiment$emulators) {
  
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
    dirMain, experiment_dir, train_ids, zDecision, iStep, ml,
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