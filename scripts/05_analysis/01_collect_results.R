#!/usr/bin/env Rscript

# ==============================================================================
# Collect final emulator results across experiment folds
#
# For each held-out basin and emulator, this script retrieves the final candidate
# set, keeps candidates successfully evaluated with FUSE, and selects the one
# ranked highest by emulator-predicted NKGE.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 3L) {
  stop("Usage: Rscript 01_collect_results.R <experiment_root> <zDecision> <dirMain>")
}

exp_root <- normalizePath(args[1], mustWork = TRUE)
zDecision <- args[2]
dirMain <- normalizePath(args[3], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(dirMain)

folds <- list.dirs(exp_root, recursive = FALSE, full.names = TRUE)

res <- list()
j <- 0L


# ==============================================================================
# Collect final test results
# ==============================================================================

for (fd in folds) {
  
  testfile <- file.path(fd, "test_basins.txt")
  
  if (!file.exists(testfile)) {
    next
  }
  
  ids <- read_basin_ids(testfile)
  step <- experiment$nRefinementSteps
  
  for (id in ids) {
    
    file_candidates <- file.path(
      fd, "outputs", paste0("zDecision_", zDecision),
      "test", id, paste0("candidates_step_", step, ".RData")
    )
    
    if (!file.exists(file_candidates)) {
      next
    }
    
    x <- load_rdata_single(file_candidates)
    
    for (ml in unique(x$emulator)) {
      
      # Keep only candidates successfully evaluated with FUSE.
      y <- x[x$emulator == ml & is.finite(x$KGEc), , drop = FALSE]
      
      if (!nrow(y)) {
        next
      }
      
      # Candidate selection is based on emulator prediction, not observed FUSE
      # performance, to preserve the independence of the held-out basin.
      y <- y[order(y$eNKGE, decreasing = TRUE), , drop = FALSE]
      best <- y[1, ]
      
      j <- j + 1L
      
      res[[j]] <- data.frame(
        fold = basename(fd),
        ID = id,
        emulator = ml,
        eNKGE = best$eNKGE,
        KGEc = best$KGEc,
        NKGEc = best$NKGEc,
        KGEe = best$KGEe,
        rank = best$rank
      )
    }
  }
}


# ==============================================================================
# Save summary table
# ==============================================================================

out <- if (length(res)) do.call(rbind, res) else data.frame()

write.csv(out, file.path(exp_root, "results_summary.csv"), row.names = FALSE)

print(out)