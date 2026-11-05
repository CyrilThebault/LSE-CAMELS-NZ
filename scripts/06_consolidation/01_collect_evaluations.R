#!/usr/bin/env Rscript
# Read-only campaign inventory and continuous-metric collection.
# Intended for LSE-CAMELS-NZ repository as of November 2026.
# DOES NOT recompute NSE/KGE; all daily/hourly comparisons in this table
# are DESCRIPTIVE until common-valid-day analysis has been performed.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L || length(args) > 4L) {
  stop("Usage: Rscript 01_collect_evaluations.R REPO OUTDIR [--check] [--strategies localcalib,allseen,kfold,cluster,loo]", call. = FALSE)
}
repo <- normalizePath(args[[1]], mustWork = TRUE)
outdir <- path.expand(args[[2]])
extra <- if (length(args) > 2L) args[3:length(args)] else character()
check_only <- "--check" %in% extra
strategy_arg <- grep("^--strategies=", extra, value = TRUE)
if (length(strategy_arg) > 1L || length(setdiff(extra, c("--check", strategy_arg))) > 0L) {
  stop("Unknown or repeated command-line option", call. = FALSE)
}
strategies <- if (length(strategy_arg)) strsplit(sub("^--strategies=", "", strategy_arg), ",", fixed = TRUE)[[1]] else c("localcalib", "allseen", "kfold", "cluster", "loo")
allowed <- c("localcalib", "allseen", "kfold", "cluster", "loo")
if (!length(strategies) || anyDuplicated(strategies) || any(!strategies %in% allowed)) stop("Invalid strategies", call. = FALSE)
if (!dir.exists(file.path(repo, "experiments"))) stop("Missing experiments directory", call. = FALSE)

read_ids <- function(path, required = TRUE) {
  if (!file.exists(path)) {
    if (required) stop("Missing catchment list: ", path, call. = FALSE)
    return(NULL)
  }
  x <- scan(path, what = character(), quiet = TRUE)
  if (!length(x) || anyNA(x) || anyDuplicated(x)) stop("Invalid catchment list: ", path, call. = FALSE)
  x
}
all_basins <- read_ids(file.path(repo, "config", "basins.txt"))
all_basins <- sort(all_basins)
resolutions <- c("daily", "hourly")

source(file.path(repo, "scripts/functions/common.R"))

# Campaign-wide configuration: no timestep argument.
cfg <- load_workflow_config(
  file.path(repo, "config", "experiment.R"),
  mode = "campaign"
)

resolutions <- c("daily", "hourly")

if (!all(resolutions %in% cfg$timesteps)) {
  stop(
    "Daily/hourly resolutions missing from campaign configuration",
    call. = FALSE
  )
}

zdecision <- as.character(cfg$zDecision)
final_step <- as.integer(cfg$nRefinementSteps)
emulators <- as.character(cfg$emulators)

if (length(zdecision) != 1L ||
    length(final_step) != 1L ||
    !length(emulators) || anyDuplicated(emulators)) {
  stop("Invalid experiment configuration", call. = FALSE)
}

# Exact evaluation layout: local SCE differs from emulator test-phase archives.
evaluation_dir <- function(resolution, strategy, unit, id, method) {
  if (strategy == "localcalib") {
    return(file.path(repo, "experiments", resolution, "localcalib", "all_basins", "evaluation", paste0("zDecision_", zdecision), id, "sce"))
  }
  file.path(repo, "experiments", resolution, strategy, unit,
            "evaluation", paste0("zDecision_", zdecision), "test", id, paste0("step_", final_step), method)
}

read_global <- function(path) {
  d <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  needed <- c("period", "NSE", "KGE.2009")
  if (!all(needed %in% names(d))) stop("Missing columns in ", path, call. = FALSE)
  if (anyDuplicated(d$period) || !setequal(d$period, c("calibration", "evaluation"))) {
    stop("Unexpected metric periods in ", path, call. = FALSE)
  }
  data.frame(period = as.character(d$period), NSE = suppressWarnings(as.numeric(d[["NSE"]])),
             KGE2009 = suppressWarnings(as.numeric(d[["KGE.2009"]])), stringsAsFactors = FALSE)
}

rows <- list()
metric_rows <- list()
partitions <- list()
missing_log <- character()
ri <- 0L
mi <- 0L
add_record <- function(res, strategy, unit, id, method) {
  ev <- evaluation_dir(res, strategy, unit, id, method)
  global_ref <- file.path(ev, if (res == "daily") "global_native.csv" else "global_daily.csv")
  native_ref <- file.path(ev, "global_native.csv")
  flood_ref <- file.path(ev, if (res == "daily") "flood_native.csv" else "flood_daily.csv")
  meta_ref <- file.path(ev, "metadata.rds")
  status <- if (!file.exists(global_ref)) "missing_continuous" else if (!file.exists(flood_ref)) "missing_flood" else if (!file.exists(meta_ref)) "missing_metadata" else "complete"
  ri <<- ri + 1L
  rows[[ri]] <<- data.frame(resolution = res, strategy = strategy, unit = unit, basin = id,
                           method = method, status = status,
                           global_file = global_ref, flood_file = flood_ref,
                           native_file = native_ref, metadata_file = meta_ref,
                           stringsAsFactors = FALSE)
  if (status == "complete") {
    required <- c(
      native_ref, flood_ref, meta_ref,
      if (res == "hourly") file.path(ev, "flood_native.csv")
    )
    if (!all(file.exists(required))) {
      status <- "incomplete_native_outputs"
      rows[[ri]]$status <<- status
    }
  }
  if (status != "complete") missing_log <<- c(missing_log, paste(res, strategy, unit, id, method, status, sep = "/"))
  # Metric table is explicitly available-data-only. Missing evaluations remain in manifest.
  if (status == "complete") {
    d <- read_global(global_ref)
    mi <<- mi + 1L
    metric_rows[[mi]] <<- data.frame(resolution = res, strategy = strategy, unit = unit,
                                    basin = id, method = method, evaluation_scale = "daily",
                                    d, stringsAsFactors = FALSE)
  }
  if (res == "hourly" && status == "complete") {
    d <- read_global(native_ref)
    mi <<- mi + 1L
    metric_rows[[mi]] <<- data.frame(resolution = res, strategy = strategy, unit = unit,
                                    basin = id, method = method, evaluation_scale = "native_hourly",
                                    d, stringsAsFactors = FALSE)
  }
}

for (res in resolutions) {
  for (strategy in strategies) {
    root <- file.path(repo, "experiments", res, strategy)
    if (!dir.exists(root)) {
      cat("NOT PRESENT:", res, strategy, "\n")
      next
    }
    if (strategy == "localcalib") {
      for (id in all_basins) add_record(res, strategy, "all_basins", id, "sce")
      next
    }
    units <- if (strategy == "allseen") "all_basins" else basename(list.dirs(root, recursive = FALSE, full.names = TRUE))
    units <- sort(units)
    if (!length(units)) {
      cat("NO EXPERIMENT UNITS:", res, strategy, "\n")
      next
    }
    for (unit in units) {
      exp_dir <- file.path(root, unit)
      test_file <- file.path(exp_dir, "test_basins.txt")
      train_file <- file.path(exp_dir, "train_basins.txt")
      test <- read_ids(test_file, required = strategy != "allseen")
      if (is.null(test)) test <- all_basins
      if (!all(test %in% all_basins)) stop("Unknown test catchment in ", test_file, call. = FALSE)
      if (strategy != "allseen") {
        train <- read_ids(train_file)
        if (any(train %in% test)) stop("Train/test overlap in ", exp_dir, call. = FALSE)
        if (!all(train %in% all_basins)) stop("Unknown train catchment in ", exp_dir, call. = FALSE)
      }
      partitions[[paste(res, strategy, unit, sep = "|")]] <- sort(test)
      for (id in sort(test)) for (method in emulators) add_record(res, strategy, unit, id, method)
    }
  }
}
if (!length(rows)) stop("No experiment inventory found", call. = FALSE)
manifest <- do.call(rbind, rows)
metrics <- if (length(metric_rows)) do.call(rbind, metric_rows) else data.frame()
rownames(manifest) <- NULL
rownames(metrics) <- NULL
k <- paste(manifest$resolution, manifest$strategy, manifest$unit, manifest$basin, manifest$method, sep = "|")
if (anyDuplicated(k)) stop("Duplicate evaluation identity", call. = FALSE)
if (nrow(metrics)) {
  k2 <- paste(metrics$resolution, metrics$strategy, metrics$unit, metrics$basin, metrics$method,
              metrics$evaluation_scale, metrics$period, sep = "|")
  if (anyDuplicated(k2)) stop("Duplicate metric identity", call. = FALSE)
}
# Resolution-specific splits must match when both sides exist.
for (key in names(partitions)) {
  fields <- strsplit(key, "|", fixed = TRUE)[[1]]
  if (fields[[1]] != "daily") next
  twin <- paste("hourly", fields[[2]], fields[[3]], sep = "|")
  if (!is.null(partitions[[twin]]) && !setequal(partitions[[key]], partitions[[twin]])) {
    stop("Daily/hourly partition mismatch: ", key, call. = FALSE)
  }
}
coverage <- aggregate(manifest$status == "complete",
                      by = list(resolution = manifest$resolution,
                                strategy = manifest$strategy,
                                method = manifest$method),
                      FUN = function(x) c(complete = sum(x), expected = length(x)))
coverage <- data.frame(coverage[c("resolution", "strategy", "method")],
                       complete = coverage$x[, "complete"], expected = coverage$x[, "expected"])
cat("\n===== CAMPAIGN COVERAGE =====\n")
print(coverage, row.names = FALSE)
cat("\nExpected evaluation identities:", nrow(manifest), "\n")
cat("Complete evaluation identities:", sum(manifest$status == "complete"), "\n")
cat("Missing or incomplete identities:", length(missing_log), "\n")
if (length(missing_log)) cat(paste(head(missing_log, 12L), collapse = "\n"), "\n")

# ==============================================================================
# Consolidate validated 05_evaluation results
# ==============================================================================

assert <- function(ok, message) {
  if (!isTRUE(ok)) stop(message, call. = FALSE)
}

equal_scalar <- function(a, b) {
  length(a) == 1L && !is.na(a) &&
    identical(as.character(a), as.character(b))
}

read_metric_table <- function(path, row, kind, hourly_native = FALSE) {

  id_col <- if (kind == "global") "basin_ID" else "ID"

  x <- read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = setNames("character", id_col)
  )

  required <- if (kind == "global") {
    c("basin_ID", "period", "ti", "tf",
      "NSE", "KGE.2009", "alpha", "beta", "r")
  } else {
    c(
      "ID", "period", "valid", "reason",
      "peak_error_pct", "volume_error_pct",
      "obs_peak_at_boundary", "sim_peak_at_boundary",
      "obs_peak_tied", "sim_peak_tied",
      if (hourly_native) {
        c("event_id", "start_time", "end_time",
          "n_hours", "peak_lag_h")
      } else {
        c("daily_unit_id", "first_day", "last_day",
          "n_events", "n_days", "peak_lag_days")
      }
    )
  }

  assert(
    all(required %in% names(x)),
    paste("Missing metric columns:", path)
  )

  assert(
    all(x[[id_col]] == row$basin) &&
      !anyNA(x[[id_col]]),
    paste("Basin identity mismatch:", path)
  )

  assert(
    all(x$period %in% c("calibration", "evaluation")) &&
      !anyNA(x$period),
    paste("Invalid metric periods:", path)
  )

  key_col <- if (kind == "global") {
    "period"
  } else if (hourly_native) {
    "event_id"
  } else {
    "daily_unit_id"
  }

  keys <- if (kind == "global") {
    x$period
  } else {
    paste(x$period, x[[key_col]], sep = "|")
  }

  assert(
    !anyNA(keys) && !anyDuplicated(keys),
    paste("Duplicate or missing metric identity:", path)
  )

  if (kind == "global") {
    assert(
      nrow(x) == 2L &&
        setequal(x$period, c("calibration", "evaluation")),
      paste("Incomplete continuous metrics:", path)
    )
  } else {
    x$valid <- as.logical(x$valid)
    assert(!anyNA(x$valid), paste("Invalid flood flags:", path))
  }

  for (metric in intersect(
    c("NSE", "KGE.2009", "alpha", "beta", "r",
      "peak_error_pct", "volume_error_pct",
      "peak_lag_days", "peak_lag_h"),
    names(x)
  )) {
    assert(is.numeric(x[[metric]]),
           paste("Non-numeric metric:", metric, path))
  }

  id <- data.frame(
    resolution = row$resolution,
    strategy = row$strategy,
    unit = row$unit,
    basin = row$basin,
    method = row$method,
    modelStep = if (row$method == "sce") NA_integer_ else final_step,
    stringsAsFactors = FALSE
  )

  result <- data.frame(
    id[rep(1L, nrow(x)), , drop = FALSE],
    x,
    source_file = rep(path, nrow(x)),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )

  rownames(result) <- NULL
  result
}

table_names <- c(
  "global_native",
  "global_daily",
  "flood_native_daily",
  "flood_native_hourly",
  "flood_daily"
)

items <- setNames(
  lapply(table_names, function(x) list()),
  table_names
)

append_item <- function(name, value) {
  items[[name]][[length(items[[name]]) + 1L]] <<- value
}

provenance <- list()

complete <- manifest[
  manifest$status == "complete",
  ,
  drop = FALSE
]

for (i in seq_len(nrow(complete))) {

  row <- complete[i, , drop = FALSE]

  md <- readRDS(row$metadata_file)

  assert(
    is.list(md) &&
      equal_scalar(md$timestep, row$resolution) &&
      equal_scalar(md$basinID, row$basin) &&
      equal_scalar(md$method, row$method) &&
      equal_scalar(md$zDecision, zdecision) &&
      equal_scalar(
        md$metric_period_rule,
        "complete_calendar_days_v1"
      ),
    paste("Evaluation metadata mismatch:", row$metadata_file)
  )

  if (row$method != "sce") {
    assert(
      equal_scalar(md$method_type, "emulator") &&
        equal_scalar(md$phase, "test") &&
        equal_scalar(md$modelStep, final_step),
      paste("Emulator metadata mismatch:", row$metadata_file)
    )
  }

  original_experiment <- gsub(
    "\\\\", "/", as.character(md$experiment_dir)
  )

  assert(
    identical(basename(original_experiment), row$unit) &&
      identical(
        basename(dirname(original_experiment)),
        row$strategy
      ),
    paste("Spatial experiment mismatch:", row$metadata_file)
  )

  provenance[[length(provenance) + 1L]] <- data.frame(
    row[c("resolution", "strategy", "unit", "basin", "method")],
    metadata_file = row$metadata_file,
    original_experiment = original_experiment,
    stringsAsFactors = FALSE
  )

  append_item(
    "global_native",
    read_metric_table(
      row$native_file, row, "global"
    )
  )

  if (row$resolution == "hourly") {
    append_item(
      "global_daily",
      read_metric_table(
        row$global_file, row, "global"
      )
    )
  }

  native_flood <- file.path(
    dirname(row$flood_file),
    "flood_native.csv"
  )

  append_item(
    if (row$resolution == "daily") {
      "flood_native_daily"
    } else {
      "flood_native_hourly"
    },
    read_metric_table(
      native_flood,
      row,
      "flood",
      hourly_native = row$resolution == "hourly"
    )
  )

  if (row$resolution == "hourly") {
    append_item(
      "flood_daily",
      read_metric_table(
        row$flood_file, row, "flood"
      )
    )
  }
}

bind_tables <- function(x) {
  if (!length(x)) return(data.frame())

  columns <- names(x[[1L]])

  assert(
    all(vapply(
      x,
      function(a) setequal(names(a), columns),
      logical(1)
    )),
    "Inconsistent schemas within a consolidated table"
  )

  result <- do.call(
    rbind,
    lapply(x, function(a) a[, columns, drop = FALSE])
  )

  rownames(result) <- NULL
  result
}

tables <- lapply(items, bind_tables)

evaluations <- c(
  list(
    schema_version = "lse_evaluations_consolidated_v1",
    repository_root_at_collection = repo,
    manifest = manifest,
    coverage = coverage,
    provenance = bind_tables(provenance),
    continuous_metrics_descriptive = metrics
  ),
  tables
)

cat("\n===== CONSOLIDATED TABLES =====\n")

for (name in table_names) {
  cat(sprintf(
    "%-24s %s\n",
    name,
    nrow(tables[[name]])
  ))
}

if (check_only) {

  cat("\nCHECK PASSED -- NO FILES WRITTEN\n")

} else {

  publish <- function() {

    assert(
      !file.exists(outdir) && !dir.exists(outdir),
      paste("Refusing to overwrite:", outdir)
    )

    parent <- dirname(outdir)

    assert(
      dir.exists(parent),
      paste("Output parent does not exist:", parent)
    )

    stage <- tempfile(
      pattern = ".lse_collector_stage_",
      tmpdir = parent
    )

    assert(
      dir.create(stage),
      paste("Cannot create staging directory:", stage)
    )

    on.exit({
      if (dir.exists(stage)) {
        unlink(stage, recursive = TRUE)
      }
    }, add = TRUE)

    saveRDS(
      evaluations,
      file.path(stage, "evaluations_consolidated.rds"),
      compress = "gzip"
    )

    write.csv(
      manifest,
      file.path(stage, "evaluation_manifest.csv"),
      row.names = FALSE,
      na = ""
    )

    write.csv(
      metrics,
      file.path(stage, "continuous_metrics_descriptive.csv"),
      row.names = FALSE,
      na = ""
    )

    write.csv(
      coverage,
      file.path(stage, "coverage_summary.csv"),
      row.names = FALSE,
      na = ""
    )

    assert(
      !file.exists(outdir) && !dir.exists(outdir),
      "Output appeared during staging"
    )

    assert(
      file.rename(stage, outdir),
      paste("Cannot publish analysis output:", outdir)
    )
  }

  publish()

  cat("\nWROTE:", outdir, "\n")
  cat("Object: evaluations_consolidated.rds\n")
}

cat(
  "\nNOTE: continuous NSE/KGE have not been recomputed",
  "on common valid days.\n"
)

cat("EVALUATION COLLECTION COMPLETE\n")
