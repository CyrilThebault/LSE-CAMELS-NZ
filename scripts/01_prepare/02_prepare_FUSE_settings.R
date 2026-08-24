#!/usr/bin/env Rscript

# ==============================================================================
# Prepare the canonical FUSE settings used by the emulator workflow
#
# The settings are copied from a reference FUSE template so that all subsequent
# basin runs use the same control files and structural-decision definitions.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 1L) {
  stop("Usage: Rscript 02_prepare_FUSE_settings.R <dirMain>")
}

dirMain <- normalizePath(args[1], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain)


# ==============================================================================
# Reference FUSE template
# ==============================================================================

source_root <- experiment$paths$fuse_template
source_settings <- file.path(source_root, "settings")

if (!dir.exists(source_settings)) {
  stop("FUSE template settings not found: ", source_settings)
}

ensure_dir(paths$settings)
ensure_dir(paths$decisions)


# ==============================================================================
# Main FUSE control file
#
# In the reference FUSE tree, fuse_control.toml may be stored at the template
# root rather than inside the settings directory.
# ==============================================================================

control <- file.path(source_root, "fuse_control.toml")

if (!file.exists(control)) {
  stop("Missing template fuse_control.toml: ", control)
}

invisible(
  file.copy(
    control,
    file.path(paths$settings, "fuse_control.toml"),
    overwrite = TRUE
  )
)


# ==============================================================================
# Standard FUSE setting files
# ==============================================================================

regular <- list.files(source_settings, full.names = TRUE)
regular <- regular[!dir.exists(regular)]
regular <- regular[basename(regular) != "list_decision_78.txt"]

if (length(regular)) {
  file.copy(regular, paths$settings, overwrite = TRUE)
}


# ==============================================================================
# Structural-decision files
#
# Only the zDecision files referenced by list_decision_78.txt are copied. This
# keeps the prepared settings consistent with the structural decisions used by
# the current FUSE experiment.
# ==============================================================================

decision_list <- file.path(paths$settings, "list_decision_78.txt")

if (!file.exists(decision_list)) {
  
  candidates <- c(
    file.path(source_root, "list_decision_78.txt"),
    file.path(dirname(source_root), "list_decision_78.txt")
  )
  
  hit <- candidates[file.exists(candidates)]
  
  if (!length(hit)) {
    stop("Could not find list_decision_78.txt in the FUSE template.")
  }
  
  file.copy(hit[1], decision_list, overwrite = TRUE)
}

zDecisions <- scan(decision_list, what = character(), quiet = TRUE)

if (!length(zDecisions)) {
  stop("No zDecision IDs found in ", decision_list)
}

dec_dir <- file.path(source_settings, "fuse_zDecisions")

if (!dir.exists(dec_dir)) {
  stop("Missing template zDecision folder: ", dec_dir)
}

dec_files <- file.path(dec_dir, paste0("fuse_zDecisions_", zDecisions, ".txt"))

missing_decisions <- dec_files[!file.exists(dec_files)]

if (length(missing_decisions)) {
  stop(
    "Missing zDecision file(s): ",
    paste(basename(missing_decisions), collapse = ", ")
  )
}

file.copy(dec_files, paths$decisions, overwrite = TRUE)

message("Canonical FUSE settings prepared in ", paths$settings)