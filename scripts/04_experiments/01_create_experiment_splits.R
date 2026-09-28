#!/usr/bin/env Rscript

# ==============================================================================
# Create experiment splits for regionalisation experiments
#
# Supported modes:
#   - allseen: all basins are used for both training and evaluation
#   - loo:         one basin is held out at a time
#   - kfold:       basins are randomly divided into K folds
#   - cluster:     one hydrological cluster is held out at a time
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3L) {
  stop(
    "Usage: Rscript 01_create_experiment_splits.R ",
    "<allseen|loo|kfold|cluster> <config_file> <dirMain> [K|cluster_column]"
  )
}

mode <- args[1]
config_file <- normalizePath(args[2], mustWork = TRUE)
dirMain <- normalizePath(args[3], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(config_file)
paths <- project_paths(dirMain, experiment)

ids <- read_basin_ids(file.path(dirMain, "config", "basins.txt"))

set.seed(experiment$seed)


# ==============================================================================
# Helper to create one fold
# ==============================================================================

make_fold <- function(base, name, train, test, meta = list()) {
  
  d <- ensure_dir(file.path(base, name))
  
  write_basin_ids(train, file.path(d, "train_basins.txt"))
  write_basin_ids(test, file.path(d, "test_basins.txt"))
  
  metadata <- c(
    list(
      type = mode,
      fold = name,
      train_basins = train,
      test_basins = test,
      seed = experiment$seed
    ),
    meta
  )
  
  save(metadata, file = file.path(d, "metadata.RData"))
}


# ==============================================================================
# Create experiment directory
# ==============================================================================

base <- ensure_dir(file.path(paths$experiments, mode))


# ==============================================================================
# All seen
#
# All basins are used for both training and evaluation. This experiment provides
# a reference for performance without spatial transfer.
# ==============================================================================

if (mode == "allseen") {
  
  make_fold(base, "all_basins", ids, ids)
  
  
  # ==============================================================================
  # Leave-one-out cross-validation
  #
  # Each basin is treated as unseen once while all remaining basins are used for
  # emulator training.
  # ==============================================================================
  
} else if (mode == "loo") {
  
  for (i in seq_along(ids)) {
    make_fold(
      base,
      sprintf("fold_%03d", i),
      setdiff(ids, ids[i]),
      ids[i],
      list(held_out = ids[i])
    )
  }
  
  
  # ==============================================================================
  # Random K-fold cross-validation
  #
  # Basins are randomly shuffled once using the experiment seed, then distributed
  # as evenly as possible among K folds.
  # ==============================================================================
  
} else if (mode == "kfold") {
  
  K <- if (length(args) >= 4L) as.integer(args[4]) else 5L
  
  if (is.na(K) || K < 2L || K > length(ids)) {
    stop("Invalid K: ", K)
  }
  
  shuffled <- sample(ids)
  fold_id <- rep(seq_len(K), length.out = length(ids))
  
  for (k in seq_len(K)) {
    
    test <- shuffled[fold_id == k]
    
    make_fold(
      base,
      sprintf("fold_%02d", k),
      setdiff(ids, test),
      test,
      list(K = K)
    )
  }
  
  
  # ==============================================================================
  # Cluster cross-validation
  #
  # Each hydrological cluster is held out in turn. Cluster labels must already be
  # available in attributes.RData, for example after deriving them from static attributes.
  # ==============================================================================
  
} else if (mode == "cluster") {

  cluster_col <- if (length(args) >= 4L) args[4] else "hydro_cluster"

  attributes <- load_rdata_single(
    file.path(paths$useful, "attributes.RData")
  )

  if (!"ID" %in% names(attributes)) {
    stop("ID column missing from attributes.RData")
  }

  if (!cluster_col %in% names(attributes)) {
    stop("Cluster column missing from attributes.RData: ", cluster_col)
  }

  attribute_ids <- as.character(attributes$ID)

  if (anyDuplicated(attribute_ids)) {
    stop("Duplicate basin ID(s) found in attributes.RData")
  }

  rows <- match(ids, attribute_ids)

  if (anyNA(rows)) {
    stop(
      "Basin(s) missing from attributes.RData: ",
      paste(ids[is.na(rows)], collapse = ", ")
    )
  }

  cluster_labels <- trimws(
    as.character(attributes[[cluster_col]][rows])
  )

  if (anyNA(cluster_labels)) {
    stop("NA cluster labels found in column: ", cluster_col)
  }

  if (any(!nzchar(cluster_labels))) {
    stop("Empty cluster labels found in column: ", cluster_col)
  }

  clusters <- unique(cluster_labels)

  # Build deterministic, filesystem-safe fold names from cluster values.
  cluster_tags <- gsub(
    "[^A-Za-z0-9._-]+",
    "_",
    as.character(clusters)
  )

  cluster_tags <- gsub(
    "^_+|_+$",
    "",
    cluster_tags
  )

  if (any(!nzchar(cluster_tags))) {
    stop(
      "At least one cluster value cannot be converted to a safe fold name."
    )
  }

  if (anyDuplicated(cluster_tags)) {

    duplicated_tags <- unique(
      cluster_tags[
        duplicated(cluster_tags)
      ]
    )

    stop(
      "Cluster values are not unique after sanitizing fold names: ",
      paste(
        duplicated_tags,
        collapse = ", "
      )
    )
  }

  if (length(clusters) < 2L) {
    stop(
      "Cluster cross-validation requires at least two distinct clusters ",
      "among the selected basins."
    )
  }

  for (k in seq_along(clusters)) {

    cluster_value <- clusters[k]
    test <- ids[cluster_labels == cluster_value]

    make_fold(
      base,
      paste0("cluster_", cluster_tags[k]),
      setdiff(ids, test),
      test,
      list(
        cluster_column = cluster_col,
        cluster_value = cluster_value
      )
    )
  }

} else {
  
  stop("Unknown split mode: ", mode)
}

message("Created experiment splits under ", base)