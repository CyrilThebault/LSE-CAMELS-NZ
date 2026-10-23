#!/usr/bin/env Rscript

# Validate the spatial partitions of one emulator experiment.
# This script never modifies the experiment directories.

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 3L) {
  stop(
    "Usage: Rscript 02_validate_experiment_splits.R ",
    "<allseen|loo|kfold|cluster> <config_file> <dirMain>"
  )
}

mode <- args[1]
config_file <- normalizePath(args[2], mustWork = TRUE)
dirMain <- normalizePath(args[3], mustWork = TRUE)

allowed <- c("allseen", "loo", "kfold", "cluster")

if (!mode %in% allowed) {
  stop("Unknown split mode: ", mode)
}

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(config_file)
paths <- project_paths(dirMain, experiment)

ids <- read_basin_ids(file.path(dirMain, "config", "basins.txt"))

base <- file.path(paths$experiments, mode)

if (!dir.exists(base)) {
  stop("Missing experiment directory: ", base)
}

entries <- list.files(
  base,
  full.names = TRUE,
  all.files = TRUE,
  no.. = TRUE
)

fold_dirs <- sort(entries[dir.exists(entries)])

if (!length(fold_dirs)) {
  stop("No experiment folds found in: ", base)
}

fold_names <- basename(fold_dirs)

valid_names <- switch(
  mode,
  allseen = fold_names == "all_basins",
  loo = grepl("^fold_[0-9]{3,}$", fold_names),
  kfold = grepl("^fold_[0-9]{2,}$", fold_names),
  cluster = grepl("^cluster_[A-Za-z0-9._-]+$", fold_names)
)

if (!all(valid_names)) {
  stop("Unexpected fold directories in: ", base)
}

tests <- vector("list", length(fold_dirs))

for (i in seq_along(fold_dirs)) {
  fold <- fold_names[i]
  directory <- fold_dirs[i]

  train <- read_basin_ids(
    file.path(directory, "train_basins.txt")
  )

  test <- read_basin_ids(
    file.path(directory, "test_basins.txt")
  )

  if (
    length(setdiff(train, ids)) ||
    length(setdiff(test, ids))
  ) {
    stop("Unknown basin ID in fold: ", fold)
  }

  if (mode == "allseen") {
    if (!setequal(train, ids) || !setequal(test, ids)) {
      stop("Invalid allseen partition: ", fold)
    }
  } else {
    if (
      length(intersect(train, test)) ||
      !setequal(train, setdiff(ids, test))
    ) {
      stop("Invalid train/test partition: ", fold)
    }
  }

  tests[[i]] <- test
}

# Every selected basin must appear exactly once across all test sets.
test_ids <- unlist(tests, use.names = FALSE)

counts <- table(factor(test_ids, levels = ids))
invalid <- ids[counts != 1L]

if (length(invalid)) {
  stop(
    length(invalid),
    " basin(s) are missing or duplicated in test sets. Examples: ",
    paste(head(invalid, 15L), collapse = ", ")
  )
}

# Mode-specific structural checks.
if (mode == "allseen") {
  if (length(fold_dirs) != 1L) {
    stop("allseen must contain exactly one fold")
  }
}

if (mode == "loo") {
  if (
    length(fold_dirs) != length(ids) ||
    any(lengths(tests) != 1L)
  ) {
    stop("Invalid LOO fold count or test-set sizes")
  }
}

if (mode == "kfold") {
  K <- experiment$kfold_K

  if (
    length(K) != 1L ||
    is.na(K) ||
    length(fold_dirs) != K ||
    diff(range(lengths(tests))) > 1L
  ) {
    stop("Invalid K-fold count or fold balance")
  }
}

if (mode == "cluster") {
  attributes <- load_rdata_single(
    file.path(paths$useful, "attributes.RData")
  )

  col <- experiment$cluster_column

  if (
    length(col) != 1L ||
    is.na(col) ||
    !all(c("ID", col) %in% names(attributes))
  ) {
    stop("Missing cluster classification column")
  }

  attribute_ids <- as.character(attributes$ID)

  if (anyNA(attribute_ids) || anyDuplicated(attribute_ids)) {
    stop("Invalid basin IDs in attributes")
  }

  rows <- match(ids, attribute_ids)

  if (anyNA(rows)) {
    stop("Basins missing from attributes")
  }

  labels <- trimws(as.character(
    attributes[[col]][rows]
  ))

  if (anyNA(labels) || any(!nzchar(labels))) {
    stop("Invalid cluster labels")
  }

  groups <- split(ids, labels)

  cluster_tags <- gsub(
    "[^A-Za-z0-9._-]+", "_", names(groups)
  )
  cluster_tags <- gsub("^_+|_+$", "", cluster_tags)

  expected_folds <- paste0("cluster_", cluster_tags)

  if (
    any(!nzchar(cluster_tags)) ||
    anyDuplicated(expected_folds) ||
    !setequal(fold_names, expected_folds)
  ) {
    stop("Cluster fold names do not match climate zones")
  }

  for (i in seq_along(tests)) {
    group_index <- match(fold_names[i], expected_folds)

    if (!setequal(tests[[i]], groups[[group_index]])) {
      stop(
        "Test basins do not match the named climate zone: ",
        fold_names[i]
      )
    }
  }
}

cat("========================================\n")
cat("Experiment:", mode, "\n")
cat("Timestep:", experiment$timestep, "\n")
cat("Basins:", length(ids), "\n")
cat("Folds:", length(fold_dirs), "\n")
cat("Unique test basins:", length(unique(test_ids)), "\n")
cat("Missing test basins: 0\n")
cat("Duplicated test basins: 0\n")
cat("PASS - Experiment splits are valid\n")
cat("========================================\n")
