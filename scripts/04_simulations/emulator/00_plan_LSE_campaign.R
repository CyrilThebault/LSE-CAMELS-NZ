#!/usr/bin/env Rscript

cli <- commandArgs(trailingOnly = TRUE)

options <- list()
i <- 1L

while (i <= length(cli)) {
  flag <- cli[i]

  if (flag == "--dry-run") {
    if (!is.null(options$dry_run)) stop("Duplicate --dry-run")
    options$dry_run <- TRUE
    i <- i + 1L
    next
  }

  if (!flag %in% c(
    "--timestep", "--split", "--fold", "--emulator"
  )) {
    stop("Unknown option: ", flag)
  }

  if (i == length(cli) ||
      startsWith(cli[i + 1L], "--")) {
    stop("Missing value for ", flag)
  }

  key <- substring(flag, 3L)

  if (!is.null(options[[key]])) {
    stop("Duplicate option: ", flag)
  }

  options[[key]] <- cli[i + 1L]
  i <- i + 2L
}

if (!isTRUE(options$dry_run)) {
  stop("--dry-run is mandatory. Execution is not implemented.")
}

dirMain <- normalizePath(getwd(), mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

campaign <- load_workflow_config(
  file.path(dirMain, "config/experiment.R"),
  mode = "campaign"
)

select_values <- function(configured, requested, label) {
  if (!is.character(configured) ||
      !length(configured) ||
      anyNA(configured) ||
      any(!nzchar(configured)) ||
      anyDuplicated(configured)) {
    stop("Invalid configured ", label)
  }

  if (is.null(requested)) return(configured)

  if (!nzchar(requested) ||
      grepl("(^,|,$|,,)", requested)) {
    stop("Invalid ", label, " selection")
  }

  selected <- trimws(
    strsplit(requested, ",", fixed = TRUE)[[1L]]
  )

  if (!length(selected) ||
      any(!nzchar(selected)) ||
      anyDuplicated(selected) ||
      any(!selected %in% configured)) {
    stop("Invalid ", label, " selection")
  }

  selected
}

timesteps <- select_values(
  campaign$timesteps, options$timestep, "timestep"
)

modes <- select_values(
  campaign$split_modes, options$split, "split"
)

emulators <- select_values(
  campaign$emulators, options$emulator, "emulator"
)

if (!is.null(options$fold) && length(modes) != 1L) {
  stop("--fold requires exactly one selected split mode")
}

ids <- read_basin_ids(
  file.path(dirMain, "config/basins.txt")
)

if (!length(ids) || anyDuplicated(ids)) {
  stop("Invalid configured basin IDs")
}

cluster_folds <- function() {
  scalar <- resolve_workflow_config(campaign, timesteps[1L])
  paths <- project_paths(dirMain, scalar)

  attributes <- load_rdata_single(
    file.path(paths$useful, "attributes.RData")
  )

  column <- campaign$cluster_column

  if (!all(c("ID", column) %in% names(attributes))) {
    stop("Missing cluster attributes")
  }

  attribute_ids <- as.character(attributes$ID)

  if (anyNA(attribute_ids) || anyDuplicated(attribute_ids)) {
    stop("Invalid attribute basin IDs")
  }

  rows <- match(ids, attribute_ids)

  if (anyNA(rows)) {
    stop("Configured basins missing from attributes")
  }

  labels <- trimws(as.character(attributes[[column]][rows]))

  if (anyNA(labels) || any(!nzchar(labels))) {
    stop("Invalid cluster labels")
  }

  tags <- gsub(
    "[^A-Za-z0-9._-]+", "_", unique(labels)
  )
  tags <- gsub("^_+|_+$", "", tags)

  if (length(tags) < 2L ||
      any(!nzchar(tags)) ||
      anyDuplicated(tags)) {
    stop("Invalid cluster folder names")
  }

  paste0("cluster_", tags)
}

expected_folds <- function(mode) {
  switch(
    mode,
    allseen = "all_basins",
    loo = sprintf("fold_%03d", seq_along(ids)),
    kfold = {
      K <- campaign$kfold_K
      if (length(K) != 1L || is.na(K) ||
          !is.finite(K) || K != floor(K) ||
          K < 2L || K > length(ids)) {
        stop("Invalid kfold_K")
      }
      sprintf("fold_%02d", seq_len(as.integer(K)))
    },
    cluster = cluster_folds(),
    stop("Unexpected split mode")
  )
}

normalize_fold <- function(value, mode) {
  if (grepl("^[0-9]+$", value) &&
      mode %in% c("kfold", "loo")) {
    number <- suppressWarnings(as.integer(value))

    if (is.na(number) || number < 1L) {
      stop("Invalid fold number")
    }

    return(sprintf(
      if (mode == "kfold") "fold_%02d" else "fold_%03d",
      number
    ))
  }

  value
}

is_link <- function(path) {
  target <- Sys.readlink(path)
  !is.na(target) && nzchar(target)
}

directory_status <- function(path, mode, fold) {

  is_link <- function(p) {
    target <- Sys.readlink(p)
    !is.na(target) && nzchar(target)
  }

  if (is_link(path)) return("SYMLINK_REVIEW")

  if (file.exists(path) && !dir.exists(path)) {
    return("BLOCKED_PATH")
  }

  if (!dir.exists(path)) return("MISSING")

  filenames <- c(
    "train_basins.txt",
    "test_basins.txt",
    "metadata.RData"
  )

  files <- file.path(path, filenames)

  if (any(vapply(files, is_link, logical(1)))) {
    return("SYMLINK_REVIEW")
  }

  if (!all(file.exists(files))) {
    return("INCOMPLETE")
  }

  partitions <- tryCatch(
    lapply(files[1:2], function(file) {
      as.character(read_basin_ids(file))
    }),
    error = function(err) NULL
  )

  if (is.null(partitions)) {
    return("TESTCASE_OR_MISMATCH")
  }

  train <- partitions[[1L]]
  test <- partitions[[2L]]
  expected <- as.character(ids)
  N <- length(expected)

  if (
    anyNA(train) ||
    anyNA(test) ||
    anyDuplicated(train) ||
    anyDuplicated(test) ||
    any(!train %in% expected) ||
    any(!test %in% expected)
  ) {
    return("TESTCASE_OR_MISMATCH")
  }

  full_coverage <- setequal(
    union(train, test),
    expected
  )

  overlap <- length(intersect(train, test))

  if (mode == "allseen") {

    structure_ok <- (
      length(train) == N &&
      length(test) == N &&
      setequal(train, expected) &&
      setequal(test, expected)
    )

  } else if (mode == "loo") {

    structure_ok <- (
      full_coverage &&
      overlap == 0L &&
      length(train) == N - 1L &&
      length(test) == 1L
    )

  } else if (mode == "kfold") {

    K <- campaign$kfold_K

    structure_ok <- (
      length(K) == 1L &&
      is.numeric(K) &&
      !is.na(K) &&
      is.finite(K) &&
      K == floor(K) &&
      K >= 2L &&
      K <= N
    )

    if (structure_ok) {
      structure_ok <- (
        full_coverage &&
        overlap == 0L &&
        length(train) + length(test) == N &&
        length(test) %in% c(
          floor(N / K),
          ceiling(N / K)
        )
      )
    }

  } else if (mode == "cluster") {

    structure_ok <- (
      full_coverage &&
      overlap == 0L &&
      length(train) > 0L &&
      length(test) > 0L
    )

  } else {
    stop("Unexpected split mode: ", mode)
  }

  if (!structure_ok) {
    return("TESTCASE_OR_MISMATCH")
  }

  # Other spatial modes require their own metadata
  # and classification-specific validation rules.
  # They are never marked fully validated here.

  if (mode != "kfold") {
    return("STRUCTURAL_ONLY")
  }

  # Validate the known kfold metadata contract.

  env <- new.env(parent = emptyenv())

  loaded <- tryCatch(
    load(files[3L], envir = env),
    error = function(err) character()
  )

  if (!identical(loaded, "metadata")) {
    return("METADATA_MISMATCH")
  }

  metadata <- env$metadata

  required <- c(
    "type", "fold",
    "train_basins", "test_basins",
    "seed", "K"
  )

  metadata_ok <- tryCatch({

    is.list(metadata) &&
      all(required %in% names(metadata)) &&
      identical(as.character(metadata$type), "kfold") &&
      identical(as.character(metadata$fold), fold) &&
      identical(as.character(metadata$train_basins), train) &&
      identical(as.character(metadata$test_basins), test) &&
      is.numeric(metadata$seed) &&
      length(metadata$seed) == 1L &&
      is.finite(metadata$seed) &&
      metadata$seed == campaign$seed &&
      is.numeric(metadata$K) &&
      length(metadata$K) == 1L &&
      is.finite(metadata$K) &&
      metadata$K == campaign$kfold_K

  }, error = function(err) FALSE)

  if (!isTRUE(metadata_ok)) {
    return("METADATA_MISMATCH")
  }

  # Any outputs or unexpected entries protect the
  # existing fold against accidental re-execution.

  entries <- list.files(
    path,
    all.files = TRUE,
    no.. = TRUE
  )

  allowed <- c(filenames, ".DS_Store")

  if (length(setdiff(entries, allowed)) > 0L) {
    return("VALIDATED_PROTECTED")
  }

  "VALIDATED_EMPTY"
}


# Preserve the validated V2 implementation.
directory_status_v2 <- directory_status

directory_status <- function(path, mode, fold) {

  status <- directory_status_v2(path, mode, fold)

  # Kfold and invalid/missing partitions keep their V2 statuses.
  if (!identical(status, "STRUCTURAL_ONLY")) {
    return(status)
  }

  train <- as.character(read_basin_ids(
    file.path(path, "train_basins.txt")
  ))

  test <- as.character(read_basin_ids(
    file.path(path, "test_basins.txt")
  ))

  expected <- as.character(ids)

  env <- new.env(parent = emptyenv())

  loaded <- tryCatch(
    load(file.path(path, "metadata.RData"), envir = env),
    error = function(e) character()
  )

  if (!identical(loaded, "metadata")) {
    return("METADATA_MISMATCH")
  }

  metadata <- env$metadata

  required <- c(
    "type", "fold", "train_basins",
    "test_basins", "seed"
  )

  if (!is.list(metadata) ||
      !all(required %in% names(metadata))) {
    return("METADATA_MISMATCH")
  }

  common_ok <- (
    identical(as.character(metadata$type), mode) &&
    identical(as.character(metadata$fold), fold) &&
    identical(as.character(metadata$train_basins), train) &&
    identical(as.character(metadata$test_basins), test) &&
    is.numeric(metadata$seed) &&
    length(metadata$seed) == 1L &&
    is.finite(metadata$seed) &&
    metadata$seed == campaign$seed
  )

  if (!isTRUE(common_ok)) {
    return("METADATA_MISMATCH")
  }

  if (mode == "allseen") {

    if (!identical(fold, "all_basins") ||
        !identical(train, expected) ||
        !identical(test, expected)) {
      return("TESTCASE_OR_MISMATCH")
    }

  } else if (mode == "loo") {

    names_expected <- sprintf(
      "fold_%03d", seq_along(expected)
    )

    index <- match(fold, names_expected)

    if (is.na(index) ||
        !identical(test, expected[index]) ||
        !identical(train, expected[-index])) {
      return("TESTCASE_OR_MISMATCH")
    }

    if (!identical(
      as.character(metadata$held_out),
      expected[index]
    )) {
      return("METADATA_MISMATCH")
    }

  } else if (mode == "cluster") {

    scalar <- resolve_workflow_config(
      campaign, campaign$timesteps[1L]
    )

    paths <- project_paths(dirMain, scalar)

    attributes <- load_rdata_single(
      file.path(paths$useful, "attributes.RData")
    )

    column <- campaign$cluster_column

    if (!all(c("ID", column) %in% names(attributes))) {
      stop("Missing cluster attribute or basin IDs")
    }

    attribute_ids <- as.character(attributes$ID)

    if (anyNA(attribute_ids) ||
        anyDuplicated(attribute_ids)) {
      stop("Invalid attribute basin IDs")
    }

    rows <- match(expected, attribute_ids)

    if (anyNA(rows)) {
      stop("Configured basins absent from attributes")
    }

    labels <- trimws(as.character(
      attributes[[column]][rows]
    ))

    if (anyNA(labels) || any(!nzchar(labels))) {
      stop("Invalid cluster classification")
    }

    values <- unique(labels)

    tags <- gsub(
      "[^A-Za-z0-9._-]+", "_", values
    )

    tags <- gsub("^_+|_+$", "", tags)

    if (any(!nzchar(tags)) ||
        anyDuplicated(tags)) {
      stop("Invalid cluster folder tags")
    }

    names_expected <- paste0("cluster_", tags)
    index <- match(fold, names_expected)

    if (is.na(index)) {
      return("TESTCASE_OR_MISMATCH")
    }

    cluster_value <- values[index]

    expected_test <- expected[
      labels == cluster_value
    ]

    expected_train <- setdiff(
      expected, expected_test
    )

    if (!identical(test, expected_test) ||
        !identical(train, expected_train)) {
      return("TESTCASE_OR_MISMATCH")
    }

    cluster_metadata_ok <- (
      identical(
        as.character(metadata$cluster_column),
        as.character(column)
      ) &&
      identical(
        as.character(metadata$cluster_value),
        as.character(cluster_value)
      )
    )

    if (!cluster_metadata_ok) {
      return("METADATA_MISMATCH")
    }

  } else {
    stop("Unexpected spatial mode: ", mode)
  }

  # Preserve any existing scientific artifacts.
  entries <- list.files(
    path, all.files = TRUE, no.. = TRUE
  )

  allowed <- c(
    "train_basins.txt",
    "test_basins.txt",
    "metadata.RData",
    ".DS_Store"
  )

  if (length(setdiff(entries, allowed))) {
    return("VALIDATED_PROTECTED")
  }

  "VALIDATED_EMPTY"
}


planned <- list()

for (timestep in timesteps) {
  scalar <- resolve_workflow_config(campaign, timestep)
  paths <- project_paths(dirMain, scalar)

  for (mode in modes) {
    folds <- expected_folds(mode)

    if (!is.null(options$fold)) {
      requested <- normalize_fold(options$fold, mode)

      if (!requested %in% folds) {
        stop("Unknown fold for ", mode, ": ", requested)
      }

      folds <- requested
    }

    for (fold in folds) {
      directory <- file.path(paths$experiments, mode, fold)

      planned[[length(planned) + 1L]] <- data.frame(
        timestep = timestep,
        split = mode,
        fold = fold,
        emulators = paste(emulators, collapse = ","),
        directory = directory,
        status = directory_status(directory, mode, fold),
        stringsAsFactors = FALSE
      )
    }
  }
}

plan <- do.call(rbind, planned)
rownames(plan) <- NULL


audit_mode_root <- function(root, expected_folds) {

  is_link <- function(path) {
    target <- Sys.readlink(path)
    !is.na(target) && nzchar(target)
  }

  result <- list(
    root_exists = FALSE,
    root_artifact = FALSE,
    unexpected = character()
  )

  if (is_link(root)) {
    result$unexpected <- "MODE_ROOT_SYMLINK"
    return(result)
  }

  if (file.exists(root) && !dir.exists(root)) {
    result$unexpected <- "MODE_ROOT_NOT_DIRECTORY"
    return(result)
  }

  if (!dir.exists(root)) return(result)

  result$root_exists <- TRUE

  entries <- list.files(
    root, all.files = TRUE, no.. = TRUE
  )

  allowed <- c(
    expected_folds,
    "results_summary.csv",
    ".DS_Store"
  )

  unexpected <- setdiff(entries, allowed)

  for (name in intersect(entries, expected_folds)) {
    path <- file.path(root, name)

    if (is_link(path) || !dir.exists(path)) {
      unexpected <- c(
        unexpected, paste0("INVALID_FOLD:", name)
      )
    }
  }

  for (name in intersect(
    entries, c("results_summary.csv", ".DS_Store")
  )) {
    path <- file.path(root, name)

    if (is_link(path) ||
        !file.exists(path) ||
        dir.exists(path)) {

      unexpected <- c(
        unexpected, paste0("INVALID_AUXILIARY:", name)
      )
    }
  }

  result$root_artifact <- (
    "results_summary.csv" %in% entries
  )

  result$unexpected <- sort(unique(unexpected))
  result
}


# Validate every configured fold in the selected spatial mode.
# The --fold CLI filter does not restrict this global audit.

check_mode_group <- function(timestep, mode) {

  scalar <- resolve_workflow_config(campaign, timestep)

  root <- file.path(
    project_paths(dirMain, scalar)$experiments,
    mode
  )

  folds <- expected_folds(mode)

  audit <- audit_mode_root(root, folds)

  statuses <- setNames(
    vapply(folds, function(fold) {
      directory_status(
        file.path(root, fold),
        mode,
        fold
      )
    }, character(1)),
    folds
  )

  valid_states <- c(
    "VALIDATED_EMPTY",
    "VALIDATED_PROTECTED"
  )

  valid <- statuses %in% valid_states
  missing <- statuses == "MISSING"
  blocked <- !(valid | missing)

  n_valid <- sum(valid)
  n_missing <- sum(missing)
  n_blocked <- sum(blocked)

  if (length(audit$unexpected) > 0L ||
      n_blocked > 0L) {

    state <- "BLOCKED"

  } else if (n_missing > 0L) {

    state <- "INCOMPLETE"

  } else {

    # Only complete, individually validated groups
    # reach this point.

    trains <- lapply(folds, function(fold) {
      as.character(read_basin_ids(
        file.path(root, fold, "train_basins.txt")
      ))
    })

    tests <- lapply(folds, function(fold) {
      as.character(read_basin_ids(
        file.path(root, fold, "test_basins.txt")
      ))
    })

    expected <- as.character(ids)

    if (mode == "allseen") {

      membership_ok <- (
        length(tests) == 1L &&
        identical(trains[[1L]], expected) &&
        identical(tests[[1L]], expected)
      )

    } else {

      all_tests <- unlist(tests, use.names = FALSE)

      membership_ok <- (
        length(all_tests) == length(expected) &&
        !anyDuplicated(all_tests) &&
        setequal(all_tests, expected)
      )
    }

    if (!membership_ok) {

      state <- "GLOBAL_MEMBERSHIP_MISMATCH"

    } else if (mode == "kfold") {

      # Reconstruct the exact configured K-fold
      # partition using the current R RNG.

      K <- as.integer(campaign$kfold_K)

      set.seed(campaign$seed)

      shuffled <- sample(expected)
      assigned <- rep(
        seq_len(K),
        length.out = length(expected)
      )

      expected_tests <- lapply(seq_len(K), function(k) {
        shuffled[assigned == k]
      })

      expected_trains <- lapply(expected_tests, function(x) {
        setdiff(expected, x)
      })

      reproducible <- all(vapply(
        seq_len(K),
        function(k) {
          identical(tests[[k]], expected_tests[[k]]) &&
            identical(trains[[k]], expected_trains[[k]])
        },
        logical(1)
      ))

      if (!reproducible) {

        state <- "SEED_OR_COVERAGE_MISMATCH"

      } else if (
        any(statuses == "VALIDATED_PROTECTED") ||
        audit$root_artifact
      ) {

        state <- "VALIDATED_PROTECTED"

      } else {

        state <- "VALIDATED_EMPTY"
      }

    } else if (
      any(statuses == "VALIDATED_PROTECTED") ||
      audit$root_artifact
    ) {

      state <- "VALIDATED_PROTECTED"

    } else {

      state <- "VALIDATED_EMPTY"
    }
  }

  list(
    status = state,
    valid = n_valid,
    missing = n_missing,
    blocked = n_blocked,
    unexpected = length(audit$unexpected),
    root_artifact = audit$root_artifact,
    unexpected_names = audit$unexpected
  )
}

cat("\n===== GLOBAL SPATIAL VALIDATION =====\n")

for (timestep in timesteps) {
  for (mode in modes) {

    result <- check_mode_group(timestep, mode)

    cat(sprintf(
      paste0(
        "GLOBAL_MODE %s %s %s ",
        "valid=%d missing=%d blocked=%d ",
        "unexpected=%d root_artifact=%d\n"
      ),
      timestep,
      mode,
      result$status,
      result$valid,
      result$missing,
      result$blocked,
      result$unexpected,
      as.integer(result$root_artifact)
    ))

    if (result$unexpected > 0L) {
      cat(
        "UNEXPECTED_ROOT_ENTRIES",
        timestep,
        mode,
        paste(result$unexpected_names, collapse = ","),
        "\n"
      )
    }
  }
}

cat("Global validation examines every configured fold.\n")
cat("Mode-level CSV artifacts are protected independently.\n")


cat("===== CAMPAIGN DRY RUN =====\n")
cat("Timesteps:", paste(timesteps, collapse = ", "), "\n")
cat("Modes:", paste(modes, collapse = ", "), "\n")
cat("Emulators:", paste(emulators, collapse = ", "), "\n")
cat("Configured basins:", length(ids), "\n")
cat("Planned fold executions:", nrow(plan), "\n")

cat("\n===== PLAN BY RESOLUTION AND MODE =====\n")

groups <- unique(plan[, c("timestep", "split")])

for (j in seq_len(nrow(groups))) {
  x <- subset(
    plan,
    timestep == groups$timestep[j] &
      split == groups$split[j]
  )

  cat(
    groups$timestep[j],
    groups$split[j],
    ":", nrow(x), "fold(s)\n"
  )
}

cat("\n===== DIRECTORY PREFLIGHT =====\n")
print(table(plan$status))

for (state in sort(unique(plan$status))) {
  cat("STATUS_COUNT", state, sum(plan$status == state), "\n")
}

cat("\n===== PLAN PREVIEW =====\n")

preview <- head(plan, 12L)

print(
  preview[, c(
    "timestep", "split", "fold", "emulators", "status"
  )],
  row.names = FALSE,
  right = FALSE
)

if (nrow(plan) > nrow(preview)) {
  cat(
    "...", nrow(plan) - nrow(preview),
    "additional fold executions omitted from preview\n"
  )
}

if (nrow(plan) == 1L) {
  cat("\nSelected directory:\n", plan$directory[1L], "\n")
}

cat("\nVALIDATED_PROTECTED: partition validated with existing artifacts.\n")
cat("All other nonvalidated statuses block execution.\n")

cat("\nDRY RUN ONLY\n")
cat("NO TRAINING, GA, FUSE OR HPC SUBMISSION\n")
