#!/usr/bin/env Rscript

# ==============================================================================
# Create experiment splits for regionalisation experiments
#
# Supported modes:
#   - upper_bound: all basins are used for both training and evaluation
#   - loo:         one basin is held out at a time
#   - kfold:       basins are randomly divided into K folds
#   - cluster:     one hydrological cluster is held out at a time
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2L) {
  stop("Usage: Rscript 01_create_experiment_splits.R <upper_bound|loo|kfold|cluster> <dirMain> [K|cluster_column]")
}

mode <- args[1]
dirMain <- normalizePath(args[2], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(dirMain)

btab <- read_basin_table(file.path(dirMain, "config", "basins.txt"))
ids <- as.character(btab$ID)

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

base <- ensure_dir(file.path(dirMain, "experiments", mode))


# ==============================================================================
# Upper bound
#
# All basins are used for both training and evaluation. This is not a
# regionalisation experiment, but provides the optimistic upper bound.
# ==============================================================================

if (mode == "upper_bound") {
  
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
  
  K <- if (length(args) >= 3L) as.integer(args[3]) else 5L
  
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
  # available in basins.txt, for example after deriving them from static attributes.
  # ==============================================================================
  
} else if (mode == "cluster") {
  
  cluster_col <- if (length(args) >= 3L) args[3] else "hydro_cluster"
  
  if (!cluster_col %in% names(btab)) {
    stop("Cluster column missing from basins.txt: ", cluster_col)
  }
  
  if (anyNA(btab[[cluster_col]])) {
    stop("NA cluster labels found in column: ", cluster_col)
  }
  
  clusters <- unique(btab[[cluster_col]])
  
  for (k in seq_along(clusters)) {
    
    cluster_value <- clusters[k]
    test <- ids[btab[[cluster_col]] == cluster_value]
    
    make_fold(
      base,
      sprintf("cluster_%02d", k),
      setdiff(ids, test),
      test,
      list(cluster_column = cluster_col, cluster_value = cluster_value)
    )
  }
  
} else {
  
  stop("Unknown split mode: ", mode)
}

message("Created experiment splits under ", base)