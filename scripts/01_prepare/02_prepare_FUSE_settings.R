#!/usr/bin/env Rscript

# ==============================================================================
# Prepare the canonical FUSE settings used by the emulator workflow
#
# The settings are copied from a reference FUSE template so that all subsequent
# basin runs use the same control files and structural-decision definitions.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- paste(
  "Usage: Rscript 02_prepare_FUSE_settings.R",
  "<config_file> <dirMain> --timestep <daily|hourly> [--force]"
)

if (
  !(length(args) %in% c(4L, 5L)) ||
  args[3] != "--timestep" ||
  (length(args) == 5L && args[5] != "--force")
) {
  stop(usage)
}

workflow_timestep <- args[4]

if (!(workflow_timestep %in% c("daily", "hourly"))) {
  stop("Invalid --timestep: ", workflow_timestep, ". ", usage)
}

force <- length(args) == 5L

config_file <- normalizePath(args[1], mustWork = TRUE)
dirMain <- normalizePath(args[2], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))

experiment <- load_workflow_config(
  config_file,
  timestep = workflow_timestep
)
paths <- project_paths(dirMain, experiment)


# ==============================================================================
# Reference FUSE template
# ==============================================================================

source_root <- experiment$paths$fuse_template
source_settings <- file.path(source_root, "settings")

if (!dir.exists(source_settings)) {
  stop("FUSE template settings not found: ", source_settings)
}

# ==============================================================================
# Standard FUSE setting files
# ==============================================================================

setting_files <- c("fuse_zConstraints_snow.txt", "fuse_zNumerix.txt")

source_files <- file.path(source_settings, setting_files)
missing_files <- source_files[!file.exists(source_files)]

if (length(missing_files)) {
  stop("Missing FUSE setting file(s): ", paste(basename(missing_files), collapse = ", "))
}

# ==============================================================================
# Structural-decision files
#
# Only the zDecision files referenced by list_decision_78.txt are copied. This
# keeps the prepared settings consistent with the structural decisions used by
# the current FUSE experiment.
# ==============================================================================

source_decision_list <- file.path(source_settings, "list_decision_78.txt")
decision_list <- file.path(paths$settings, "list_decision_78.txt")

if (!file.exists(source_decision_list)) {
  stop("Missing list_decision_78.txt in FUSE template: ", source_decision_list)
}

decision_table <- read.table(source_decision_list, header = TRUE, sep = ";", stringsAsFactors = FALSE, check.names = FALSE)

if (!"ID" %in% names(decision_table)) {
  stop("Column 'ID' missing from ", decision_list)
}

zDecisions <- unique(as.character(decision_table$ID))

if (!length(zDecisions)) {
  stop("No zDecision IDs found in ", decision_list)
}

source_decisions <- file.path(source_settings, "fuse_zDecisions")

if (!dir.exists(source_decisions)) {
  stop("Missing template zDecision folder: ", source_decisions)
}

dec_files <- file.path(source_decisions, paste0("fuse_zDecisions_", zDecisions, ".txt"))
missing_decisions <- dec_files[!file.exists(dec_files)]

if (length(missing_decisions)) {
  stop("Missing zDecision file(s): ", paste(basename(missing_decisions), collapse = ", "))
}

# ==============================================================================
# Check existing outputs before copying any files
# ==============================================================================

destination_files <- c(
  file.path(paths$settings, setting_files),
  decision_list,
  file.path(paths$decisions, basename(dec_files))
)

existing_files <- destination_files[file.exists(destination_files)]

if (length(existing_files) > 0L && !force) {
  stop(
    "FUSE settings already exist:\n",
    paste(existing_files, collapse = "\n"),
    "\nUse --force to explicitly allow replacement."
  )
}

# ==============================================================================
# Copy validated FUSE settings
# ==============================================================================

ensure_dir(paths$settings)
ensure_dir(paths$decisions)

ok <- file.copy(source_files, paths$settings, overwrite = force)

if (!all(ok)) {
  stop("Failed to copy one or more canonical FUSE setting files.")
}

if (!file.copy(source_decision_list, decision_list, overwrite = force)) {
  stop("Could not copy list_decision_78.txt.")
}

ok <- file.copy(dec_files, paths$decisions, overwrite = force)

if (!all(ok)) {
  stop("Failed to copy one or more zDecision files.")
}

message("Canonical FUSE settings prepared in ", paths$settings)
message("Number of structural decisions: ", length(zDecisions))