#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Create the spatial experiment splits selected in the workflow configuration.
#
# Usage:
#   bash run_create_experiment_splits.sh <DIR_MAIN> <CONFIG_FILE> --timestep hourly
#   bash run_create_experiment_splits.sh <DIR_MAIN> <CONFIG_FILE> --timestep hourly --modes loo
#   bash run_create_experiment_splits.sh <DIR_MAIN> <CONFIG_FILE> --timestep hourly --modes allseen,loo
#
# Existing experiment directories are never overwritten.
# ==============================================================================

if [[ "$#" -ne 4 && "$#" -ne 6 && "$#" -ne 7 ]]; then
  echo "Usage: bash run_create_experiment_splits.sh <DIR_MAIN> <CONFIG_FILE> --timestep <daily|hourly> [--modes mode1,mode2 [--force]]" >&2
  exit 1
fi

DIR_MAIN="$(cd "$1" && pwd -P)"
CONFIG_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"

# Required explicit scientific timestep.
if [[ "$3" != "--timestep" ]]; then
  echo "Expected --timestep <daily|hourly>" >&2
  exit 2
fi

TIMESTEP="$4"

case "$TIMESTEP" in
  daily|hourly)
    ;;
  *)
    echo "Invalid --timestep: $TIMESTEP" >&2
    exit 2
    ;;
esac


REQUESTED_MODES=""
FORCE="false"

if [[ "$#" -ge 6 ]]; then
  if [[ "$5" != "--modes" || -z "$6" ]]; then
    echo "Expected --modes followed by comma-separated experiment modes" >&2
    exit 1
  fi

  REQUESTED_MODES="$6"
fi

if [[ "$#" -eq 7 ]]; then
  if [[ "$7" != "--force" ]]; then
    echo "Unknown option: $7" >&2
    exit 1
  fi

  FORCE="true"
fi

SPLIT_SCRIPT="$DIR_MAIN/scripts/03_experiments/01_create_experiment_splits.R"
VALIDATE_SCRIPT="$DIR_MAIN/scripts/03_experiments/02_validate_experiment_splits.R"

for required_file in \
  "$CONFIG_FILE" \
  "$SPLIT_SCRIPT" \
  "$VALIDATE_SCRIPT" \
  "$DIR_MAIN/config/basins.txt" \
  "$DIR_MAIN/scripts/functions/common.R" \
  "$DIR_MAIN/scripts/functions/basins.R"
do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done

PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/lse_splits.XXXXXXXX")"
trap 'rm -f "$PLAN_FILE"' EXIT

# ==============================================================================
# Validate the selected experiments before creating any output directory.
# ==============================================================================

Rscript --vanilla - \
  "$DIR_MAIN" \
  "$CONFIG_FILE" \
  "$REQUESTED_MODES" \
  "$PLAN_FILE" \
  "$FORCE" \
  "$TIMESTEP" <<'RS'

args <- commandArgs(trailingOnly = TRUE)

dirMain <- args[1]
config_file <- args[2]
requested_modes <- args[3]
plan_file <- args[4]
force <- identical(args[5], "true")
stopifnot(length(args) == 6L)
timestep <- args[6]

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(
  config_file,
  timestep = timestep
)
paths <- project_paths(dirMain, experiment)

ids <- read_basin_ids(file.path(dirMain, "config", "basins.txt"))

allowed <- c("allseen", "loo", "kfold", "cluster")
configured <- experiment$split_modes

if (
  !is.character(configured) ||
  !length(configured) ||
  anyNA(configured) ||
  any(!configured %in% allowed) ||
  anyDuplicated(configured)
) {
  stop("Invalid experiment$split_modes configuration")
}

if (nzchar(requested_modes)) {
  modes <- trimws(strsplit(
    requested_modes, ",", fixed = TRUE
  )[[1]])

  if (
    !length(modes) ||
    any(!nzchar(modes)) ||
    anyDuplicated(modes) ||
    any(!modes %in% configured)
  ) {
    stop(
      "Invalid --modes selection. Configured modes: ",
      paste(configured, collapse = ", ")
    )
  }

} else {
  modes <- configured
}

params <- rep("", length(modes))

# ==============================================================================
# Validate K-fold settings.
# ==============================================================================

if ("kfold" %in% modes) {
  K <- experiment$kfold_K

  if (
    !is.numeric(K) ||
    length(K) != 1L ||
    is.na(K) ||
    !is.finite(K) ||
    K != floor(K) ||
    K < 2L ||
    K > length(ids)
  ) {
    stop("Invalid experiment$kfold_K")
  }

  params[modes == "kfold"] <- as.character(as.integer(K))
}

# ==============================================================================
# Validate cluster classification.
# ==============================================================================

if ("cluster" %in% modes) {
  cluster_col <- experiment$cluster_column

  if (
    !is.character(cluster_col) ||
    length(cluster_col) != 1L ||
    is.na(cluster_col) ||
    !nzchar(trimws(cluster_col)) ||
    grepl("[\t\r\n]", cluster_col)
  ) {
    stop("Invalid experiment$cluster_column")
  }

  attributes <- load_rdata_single(
    file.path(paths$useful, "attributes.RData")
  )

  if (!all(c("ID", cluster_col) %in% names(attributes))) {
    stop("Missing ID or cluster column: ", cluster_col)
  }

  attribute_ids <- as.character(attributes$ID)

  if (anyNA(attribute_ids) || anyDuplicated(attribute_ids)) {
    stop("Invalid basin IDs in attributes.RData")
  }

  rows <- match(ids, attribute_ids)

  if (anyNA(rows)) {
    stop("Selected basins missing from attributes.RData")
  }

  labels <- trimws(as.character(
    attributes[[cluster_col]][rows]
  ))

  if (
    anyNA(labels) ||
    any(!nzchar(labels)) ||
    length(unique(labels)) < 2L
  ) {
    stop("Invalid or incomplete cluster classification")
  }

  clusters <- unique(labels)

  tags <- gsub("[^A-Za-z0-9._-]+", "_", clusters)
  tags <- gsub("^_+|_+$", "", tags)

  if (any(!nzchar(tags)) || anyDuplicated(tags)) {
    stop("Cluster labels produce invalid or duplicate folder names")
  }

  params[modes == "cluster"] <- cluster_col
}

# ==============================================================================
# Protect existing experiments.
# Only the selected modes are inspected.
# ==============================================================================

destinations <- file.path(paths$experiments, modes)

# Existing split-only directories may be replaced explicitly.
# Unknown files, nested directories and symbolic links are never removed.

is_link <- function(path) {
  target <- Sys.readlink(path)
  !is.na(target) && nzchar(target)
}

is_split_only <- function(path, mode) {
  if (is_link(path) || !dir.exists(path)) {
    return(FALSE)
  }

  entries <- list.files(
    path, all.files = TRUE, no.. = TRUE, full.names = TRUE
  )

  for (entry in entries) {
    if (is_link(entry)) {
      return(FALSE)
    }

    name <- basename(entry)

    if (name == ".DS_Store" && !dir.exists(entry)) {
      next
    }

    if (!dir.exists(entry)) {
      return(FALSE)
    }

    valid_fold <- switch(
      mode,
      allseen = identical(name, "all_basins"),
      loo = grepl("^fold_[0-9]{3,}$", name),
      kfold = grepl("^fold_[0-9]{2,}$", name),
      cluster = grepl("^cluster_[A-Za-z0-9._-]+$", name),
      FALSE
    )

    if (!valid_fold) {
      return(FALSE)
    }

    files <- list.files(
      entry, all.files = TRUE, no.. = TRUE, full.names = TRUE
    )

    allowed_files <- c(
      "train_basins.txt",
      "test_basins.txt",
      "metadata.RData",
      ".DS_Store"
    )

    if (
      any(vapply(files, is_link, logical(1))) ||
      any(dir.exists(files)) ||
      any(!basename(files) %in% allowed_files)
    ) {
      return(FALSE)
    }
  }

  TRUE
}

occupied <- vapply(destinations, function(d) {
  if (is_link(d)) {
    return(TRUE)
  }

  if (!file.exists(d)) {
    return(FALSE)
  }

  if (!dir.exists(d)) {
    return(TRUE)
  }

  length(
    list.files(d, all.files = TRUE, no.. = TRUE)
  ) > 0L
}, logical(1))

if (any(occupied)) {
  if (!force) {
    stop(
      "Selected experiment directories already contain files or results:\n",
      paste(destinations[occupied], collapse = "\n"),
      "\nNo experiment splits were created."
    )
  }

  replaceable <- vapply(
    which(occupied),
    function(i) is_split_only(destinations[i], modes[i]),
    logical(1)
  )

  if (any(!replaceable)) {
    blocked <- destinations[which(occupied)[!replaceable]]

    stop(
      "Cannot replace experiments containing results or unknown files:\n",
      paste(blocked, collapse = "\n"),
      "\nNo experiment splits were modified."
    )
  }
}

# Use a placeholder for modes without parameters.
plan_params <- ifelse(nzchar(params), params, "-")

writeLines(
  paste(modes, plan_params, sep = "\t"),
  plan_file
)

if (force && any(occupied)) {
  for (d in destinations[occupied]) {
    unlink(d, recursive = TRUE)

    if (file.exists(d) || dir.exists(d)) {
      stop("Could not remove old split-only directory: ", d)
    }

    cat("Removed old split-only directory:", d, "\n")
  }
}

cat("Selected basins:", length(ids), "\n")
cat("Selected modes:", paste(modes, collapse = ", "), "\n")
cat("Preflight validation passed.\n")

RS

# ==============================================================================
# Create the selected experiments.
# ==============================================================================

while IFS=$'\t' read -r MODE PARAM; do
  echo "========================================"
  echo "Creating experiment splits: $MODE"
  echo "========================================"

  case "$MODE" in
    allseen|loo)
      Rscript --vanilla "$SPLIT_SCRIPT" \
        "$MODE" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP"
      ;;

    kfold|cluster)
      Rscript --vanilla "$SPLIT_SCRIPT" \
        "$MODE" "$CONFIG_FILE" "$DIR_MAIN" "$PARAM" --timestep "$TIMESTEP"
      ;;

    *)
      echo "Unexpected experiment mode: $MODE" >&2
      exit 1
      ;;
  esac

  echo "Validating experiment splits: $MODE"

  Rscript --vanilla "$VALIDATE_SCRIPT" \
    "$MODE" "$CONFIG_FILE" "$DIR_MAIN" --timestep "$TIMESTEP"

done < "$PLAN_FILE"

echo "========================================"
echo "Selected experiment splits created and validated successfully."
echo "========================================"
