#!/usr/bin/env Rscript

# ==============================================================================
# LSE-CAMELS-NZ
# 06_analysis / 02_pair_floods.R
#
# Pair existing daily flood-unit metrics from the consolidated evaluation RDS.
#
# Usage:
#   Rscript 02_pair_floods.R EVALUATIONS_RDS OUTDIR [--check]
#
# Principles:
#   - Read consolidated evaluation results, not individual evaluation CSV files
#   - Match the same simulation identity and canonical daily flood unit
#   - Never redetect events
#   - Never recalculate peak, volume or timing metrics
#   - Keep original metric values and validity information
#   - Summarize by basin to avoid event-count weighting across basins
#   - Never overwrite an existing output
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (
  !(length(args) %in% c(2L, 3L)) ||
  (length(args) == 3L && args[[3L]] != "--check")
) {
  stop(
    "Usage: Rscript 02_pair_floods.R EVALUATIONS_RDS OUTDIR [--check]",
    call. = FALSE
  )
}

input_file <- normalizePath(args[[1L]], mustWork = TRUE)
outdir <- path.expand(args[[2L]])
check_only <- length(args) == 3L

assert <- function(condition, message) {
  if (!isTRUE(condition)) {
    stop(message, call. = FALSE)
  }
}

makekey <- function(x, columns) {
  do.call(
    paste,
    c(unname(x[columns]), sep = "|")
  )
}

median_finite <- function(x) {
  x <- x[is.finite(x)]
  if (!length(x)) return(NA_real_)
  stats::median(x)
}

# ==============================================================================
# 1. Load consolidated evaluations
# ==============================================================================

cat("\n===== INPUT =====\n")
cat("RDS:", input_file, "\n")
cat("Mode:", if (check_only) "CHECK" else "PAIR", "\n")

evaluations <- readRDS(input_file)

assert(
  is.list(evaluations) &&
    identical(
      evaluations$schema_version,
      "lse_evaluations_consolidated_v1"
    ),
  "Unsupported evaluation RDS schema"
)

required_objects <- c(
  "manifest",
  "flood_native_daily",
  "flood_daily"
)

assert(
  all(required_objects %in% names(evaluations)),
  "Missing consolidated evaluation objects"
)

manifest <- evaluations$manifest
daily <- evaluations$flood_native_daily
hourly <- evaluations$flood_daily

assert(
  is.data.frame(manifest) &&
    is.data.frame(daily) &&
    is.data.frame(hourly),
  "Invalid consolidated tables"
)

# ==============================================================================
# 2. Validate table structure
# ==============================================================================

simulation_columns <- c(
  "strategy",
  "unit",
  "basin",
  "method",
  "modelStep"
)

identity_columns <- c(
  "period",
  "ID",
  "daily_unit_id"
)

metric_columns <- c(
  "peak_error_pct",
  "volume_error_pct",
  "peak_lag_days"
)

required_flood_columns <- c(
  "resolution",
  simulation_columns,
  identity_columns,
  "first_day",
  "last_day",
  "n_events",
  "n_days",
  "valid",
  "reason",
  metric_columns
)

for (resolution in c("daily", "hourly")) {

  x <- if (resolution == "daily") daily else hourly

  assert(
    all(required_flood_columns %in% names(x)),
    paste("Incomplete", resolution, "flood table")
  )

  assert(
    nrow(x) > 0L,
    paste("Empty", resolution, "flood table")
  )

  assert(
    all(x$resolution == resolution) &&
      !anyNA(x$resolution),
    paste("Incorrect resolution in", resolution, "table")
  )

  assert(
    !anyNA(x[, c(
      simulation_columns[-5L],
      identity_columns,
      "first_day",
      "last_day"
    )]),
    paste("Missing flood identities in", resolution)
  )

  assert(
    all(as.character(x$ID) == as.character(x$basin)),
    paste("Basin identity mismatch in", resolution)
  )

  assert(
    all(x$period %in% c("calibration", "evaluation")),
    paste("Unexpected period in", resolution)
  )

  assert(
    is.logical(x$valid) && !anyNA(x$valid),
    paste("Invalid validity flags in", resolution)
  )

  for (metric in metric_columns) {
    assert(
      is.numeric(x[[metric]]),
      paste("Non-numeric metric:", metric, resolution)
    )
  }

  keys <- makekey(
    x,
    c(simulation_columns, identity_columns)
  )

  assert(
    !anyDuplicated(keys),
    paste("Duplicate flood-unit identities in", resolution)
  )
}

assert(
  all(c(
    "resolution",
    "strategy",
    "unit",
    "basin",
    "method",
    "status"
  ) %in% names(manifest)),
  "Incomplete evaluation manifest"
)

# ==============================================================================
# 3. Identify matched simulations
# ==============================================================================

complete <- manifest[
  manifest$status == "complete",
  ,
  drop = FALSE
]

manifest_columns <- c(
  "strategy",
  "unit",
  "basin",
  "method"
)

complete_daily <- unique(makekey(
  complete[complete$resolution == "daily", , drop = FALSE],
  manifest_columns
))

complete_hourly <- unique(makekey(
  complete[complete$resolution == "hourly", , drop = FALSE],
  manifest_columns
))

matched_manifest <- intersect(
  complete_daily,
  complete_hourly
)

sim_key_daily <- makekey(daily, simulation_columns)
sim_key_hourly <- makekey(hourly, simulation_columns)

common_simulations <- intersect(
  unique(sim_key_daily),
  unique(sim_key_hourly)
)

assert(
  length(common_simulations) > 0L,
  "No matched daily/hourly flood simulations"
)

# Verify that every simulation pair has a complete manifest pair.

for (key in common_simulations) {

  i <- which(sim_key_daily == key)[1L]

  manifest_key <- makekey(
    daily[i, , drop = FALSE],
    manifest_columns
  )

  assert(
    manifest_key %in% matched_manifest,
    paste("Paired simulation missing from complete manifest:", key)
  )
}

cat("\n===== SIMULATION MATCHING =====\n")
cat("Complete daily/hourly manifest pairs:",
    length(matched_manifest), "\n")
cat("Matched flood simulation pairs:",
    length(common_simulations), "\n")

# ==============================================================================
# 4. Pair canonical daily flood units
# ==============================================================================

results <- vector(
  "list",
  length(common_simulations)
)

for (i in seq_along(common_simulations)) {

  key <- common_simulations[[i]]

  a <- daily[
    sim_key_daily == key,
    ,
    drop = FALSE
  ]

  b <- hourly[
    sim_key_hourly == key,
    ,
    drop = FALSE
  ]

  keys_a <- makekey(a, identity_columns)
  keys_b <- makekey(b, identity_columns)

  assert(
    setequal(keys_a, keys_b),
    paste("Canonical flood inventory mismatch:", key)
  )

  ab <- merge(
    a,
    b,
    by = identity_columns,
    suffixes = c("_daily", "_hourly"),
    sort = FALSE
  )

  assert(
    nrow(ab) == nrow(a) &&
      nrow(ab) == nrow(b),
    paste("Incorrect flood-unit pairing:", key)
  )

  # Canonical unit boundaries must be identical.

  for (column in c(
    "first_day",
    "last_day",
    "n_events",
    "n_days"
  )) {

    da <- ab[[paste0(column, "_daily")]]
    ho <- ab[[paste0(column, "_hourly")]]

    assert(
      identical(
        as.character(da),
        as.character(ho)
      ),
      paste("Canonical unit mismatch:", column, key)
    )
  }

  good <- ab$valid_daily & ab$valid_hourly

  out <- data.frame(
    strategy = rep(a$strategy[[1L]], nrow(ab)),
    unit = rep(a$unit[[1L]], nrow(ab)),
    basin = rep(a$basin[[1L]], nrow(ab)),
    method = rep(a$method[[1L]], nrow(ab)),
    modelStep = rep(a$modelStep[[1L]], nrow(ab)),
    period = ab$period,
    daily_unit_id = ab$daily_unit_id,
    first_day = ab$first_day_daily,
    last_day = ab$last_day_daily,
    n_events = ab$n_events_daily,
    n_days = ab$n_days_daily,
    valid_daily = ab$valid_daily,
    valid_hourly = ab$valid_hourly,
    paired_valid = good,
    reason_daily = ab$reason_daily,
    reason_hourly = ab$reason_hourly,
    stringsAsFactors = FALSE
  )

  # Preserve original metric values, including those marked invalid.
  # Exclude invalid units only when producing paired differences.

  for (metric in metric_columns) {

    d <- ab[[paste0(metric, "_daily")]]
    h <- ab[[paste0(metric, "_hourly")]]

    available <- good & is.finite(d) & is.finite(h)

    if (metric %in% c(
      "peak_error_pct",
      "volume_error_pct"
    )) {

      assert(
        all(!good | available),
        paste("Nonfinite valid flood metric:", metric, key)
      )
    }

    out[[paste0(metric, "_daily")]] <- d
    out[[paste0(metric, "_hourly")]] <- h

    out[[paste0(
      "paired_", metric, "_available"
    )]] <- available

    delta_signed <- rep(NA_real_, length(d))
    delta_absolute <- rep(NA_real_, length(d))

    delta_signed[available] <- h[available] - d[available]

    delta_absolute[available] <- (
      abs(h[available]) - abs(d[available])
    )

    out[[paste0(
      "delta_signed_", metric
    )]] <- delta_signed

    out[[paste0(
      "delta_absolute_", metric
    )]] <- delta_absolute
  }

  results[[i]] <- out
}

paired <- do.call(rbind, results)
rownames(paired) <- NULL

paired_key <- makekey(
  paired,
  c(
    simulation_columns,
    "period",
    "daily_unit_id"
  )
)

assert(
  !anyDuplicated(paired_key),
  "Duplicate paired flood rows"
)

# ==============================================================================
# 5. Basin-level scientific summaries
# ==============================================================================

group_columns <- c(
  simulation_columns,
  "period"
)

groups <- split(
  paired,
  makekey(paired, group_columns)
)

summary_rows <- lapply(groups, function(x) {

  output <- data.frame(
    strategy = x$strategy[[1L]],
    unit = x$unit[[1L]],
    basin = x$basin[[1L]],
    method = x$method[[1L]],
    modelStep = x$modelStep[[1L]],
    period = x$period[[1L]],
    n_flood_units = nrow(x),
    n_paired_valid = sum(x$paired_valid),
    stringsAsFactors = FALSE
  )

  for (metric in metric_columns) {

    available <- x[[paste0(
      "paired_", metric, "_available"
    )]]

    daily_error <- x[[paste0(metric, "_daily")]]
    hourly_error <- x[[paste0(metric, "_hourly")]]

    delta <- x[[paste0(
      "delta_absolute_", metric
    )]]

    label <- switch(
      metric,
      peak_error_pct = "peak_pct",
      volume_error_pct = "volume_pct",
      peak_lag_days = "timing_days"
    )

    output[[paste0("n_", label)]] <- sum(available)

    output[[paste0(
      "median_abs_", label, "_daily"
    )]] <- median_finite(
      abs(daily_error[available])
    )

    output[[paste0(
      "median_abs_", label, "_hourly"
    )]] <- median_finite(
      abs(hourly_error[available])
    )

    output[[paste0(
      "median_delta_abs_", label
    )]] <- median_finite(delta)

    output[[paste0(
      "fraction_improved_", label
    )]] <- if (any(available)) {
      mean(delta[available] < 0)
    } else {
      NA_real_
    }
  }

  output
})

basin_summary <- do.call(rbind, summary_rows)
rownames(basin_summary) <- NULL

basin_summary <- basin_summary[
  order(
    basin_summary$strategy,
    basin_summary$unit,
    basin_summary$basin,
    basin_summary$method,
    basin_summary$period
  ),
  ,
  drop = FALSE
]

# ==============================================================================
# 6. Consolidated analysis object
# ==============================================================================

comparison <- list(
  schema_version = "lse_flood_comparisons_v1",
  source_evaluations_rds = input_file,
  source_schema_version = evaluations$schema_version,
  matched_simulations = length(common_simulations),
  paired_units = paired,
  basin_summary = basin_summary
)

cat("\n===== PAIRED FLOOD RESULTS =====\n")
cat("Paired simulation groups:", length(common_simulations), "\n")
cat("Canonical daily units:", nrow(paired), "\n")
cat("Valid paired units:", sum(paired$paired_valid), "\n")
cat(
  "Units with paired daily timing:",
  sum(paired$paired_peak_lag_days_available),
  "\n"
)
cat("Basin-period summary rows:", nrow(basin_summary), "\n")

cat("\n===== VALIDITY BY PERIOD =====\n")

for (period in c("calibration", "evaluation")) {

  x <- paired[paired$period == period, , drop = FALSE]

  cat(
    period,
    "| units:", nrow(x),
    "| paired valid:", sum(x$paired_valid),
    "| timing available:",
    sum(x$paired_peak_lag_days_available),
    "\n"
  )
}

# ==============================================================================
# 7. Output publication
# ==============================================================================

if (check_only) {

  cat("\nCHECK MODE: no files written\n")

} else {

  assert(
    !file.exists(outdir) && !dir.exists(outdir),
    paste("Refusing to overwrite existing output:", outdir)
  )

  parent <- dirname(outdir)

  assert(
    dir.exists(parent),
    paste("Output parent does not exist:", parent)
  )

  publish <- function() {

    stage <- tempfile(
      pattern = ".lse_flood_stage_",
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
      comparison,
      file.path(stage, "flood_comparisons.rds"),
      compress = "gzip"
    )

    assert(
      !file.exists(outdir) && !dir.exists(outdir),
      "Output directory appeared during staging"
    )

    assert(
      file.rename(stage, outdir),
      paste("Cannot publish flood comparisons:", outdir)
    )
  }

  publish()

  cat("\nWROTE:", outdir, "\n")
  cat("Object: flood_comparisons.rds\n")
}

cat("\nFLOOD PAIRING COMPLETE\n")
