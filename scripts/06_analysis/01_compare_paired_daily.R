#!/usr/bin/env Rscript

# Prototype: paired daily comparison of two FUSE evaluations.
# No FUSE execution.
# Uses existing evaluation and hydrological metric functions.

args <- commandArgs(trailingOnly = TRUE)

if (
  !(length(args) %in% c(4L, 5L)) ||
  (length(args) == 5L && args[5L] != "--check")
) {
  stop(
    "Usage: <dirMain> <daily_evaluation_dir> ",
    "<hourly_evaluation_dir> <output_dir> [--check]"
  )
}

dirMain <- normalizePath(args[1L], mustWork = TRUE)
daily_dir <- normalizePath(args[2L], mustWork = TRUE)
hourly_dir <- normalizePath(args[3L], mustWork = TRUE)
output_dir <- path.expand(args[4L])

check_only <- length(args) == 5L

if (!startsWith(output_dir, "/private/tmp/")) {
  stop("Prototype outputs must remain under /private/tmp")
}

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/evaluation_series.R"))

read_eval <- function(root, name) {
  file <- file.path(root, name)
  if (!file.exists(file)) stop("Missing evaluation file: ", file)
  read.csv(file, stringsAsFactors = FALSE)
}

assert <- function(condition, message) {
  if (!isTRUE(condition)) stop(message, call. = FALSE)
}

cat("\n===== 1. EVALUATION METADATA =====\n")

md <- readRDS(file.path(daily_dir, "metadata.rds"))
mh <- readRDS(file.path(hourly_dir, "metadata.rds"))

assert(
  identical(md$timestep, "daily") &&
    identical(mh$timestep, "hourly"),
  "Incorrect evaluation resolutions"
)

assert(
  identical(md$method_type, "emulator") &&
    identical(mh$method_type, "emulator"),
  "This prototype currently supports emulator pairs only"
)

for (field in c(
  "basinID", "zDecision", "method",
  "modelStep", "phase"
)) {
  assert(
    identical(
      as.character(md[[field]]),
      as.character(mh[[field]])
    ),
    paste("Evaluation metadata mismatch:", field)
  )
}

assert(
  identical(
    basename(md$experiment_dir),
    basename(mh$experiment_dir)
  ) &&
    identical(
      basename(dirname(md$experiment_dir)),
      basename(dirname(mh$experiment_dir))
    ),
  "Spatial experiment or fold mismatch"
)

assert(
  identical(md$metric_period_rule, "complete_calendar_days_v1") &&
    identical(mh$metric_period_rule, "complete_calendar_days_v1"),
  "Incompatible or historical evaluation-period convention"
)

periods <- md$metric_periods

assert(
  identical(names(periods), names(mh$metric_periods)),
  "Different evaluation periods"
)

for (p in names(periods)) {
  for (bound in c("ti", "tf")) {
    assert(
      identical(
        as.numeric(periods[[p]][[bound]]),
        as.numeric(mh$metric_periods[[p]][[bound]])
      ),
      paste("Different effective period boundary:", p, bound)
    )
  }
}

basinID <- as.character(md$basinID)
method <- as.character(md$method)
experiment_name <- basename(dirname(md$experiment_dir))
fold <- basename(md$experiment_dir)

cat("Basin:", basinID, "\n")
cat("Emulator:", method, "\n")
cat("Experiment:", experiment_name, "\n")
cat("Fold:", fold, "\n")
cat("Step:", md$modelStep, "\n")
cat("Phase:", md$phase, "\n")
cat("Period rule:", md$metric_period_rule, "\n")
cat("PASS: compatible evaluation metadata\n")

cat("\n===== 2. PREPARE DAILY STREAMFLOW SERIES =====\n")

daily_config <- load_workflow_config(
  file.path(dirMain, "config/experiment_daily.R")
)

assert(
  identical(daily_config$timestep, "daily"),
  "Invalid daily configuration"
)

assert(
  identical(
    daily_config$timezone,
    load_workflow_config(mh$config_file)$timezone
  ),
  "Daily/hourly timezone mismatch"
)

obs_file <- file.path(
  dirMain, "data/forcings/daily",
  basinID, paste0(basinID, "_input.nc")
)

assert(file.exists(obs_file), "Original daily Qobs missing")

qobs <- read_qobs(obs_file, daily_config)

assert(
  file.exists(md$simulation_file) &&
    file.exists(mh$simulation_file),
  "Archived FUSE hydrograph missing"
)

sim_d <- readRDS(md$simulation_file)
sim_h <- readRDS(mh$simulation_file)

prepared_d <- prepare_daily_evaluation(
  qobs_daily = qobs,
  qsim = sim_d,
  simulation_timestep = "daily",
  timezone = daily_config$timezone
)

prepared_h <- prepare_daily_evaluation(
  qobs_daily = qobs,
  qsim = sim_h,
  simulation_timestep = "hourly",
  timezone = daily_config$timezone
)

cat("\nDaily diagnostics:\n")
print(prepared_d$diagnostics, row.names = FALSE)

cat("\nHourly aggregated diagnostics:\n")
print(prepared_h$diagnostics, row.names = FALSE)

calculate_metrics <- function(x) {
  result <- compute_flow_metrics(
    qsim = x[, c("time", "qSim")],
    qobs = x[, c("time", "qObs")],
    basinID = basinID,
    periods = periods
  )

  assert(
    !is.null(result) &&
      nrow(result) == length(periods),
    "Unable to compute continuous metrics"
  )

  result
}

cat("\n===== 3. REPRODUCE ARCHIVED GLOBAL METRICS =====\n")

verify_global <- function(prepared, file) {
  calculated <- calculate_metrics(prepared$paired)
  archived <- read_eval(dirname(file), basename(file))

  ix <- match(calculated$period, archived$period)

  assert(
    !anyNA(ix) &&
      nrow(archived) == nrow(calculated),
    "Archived global metric periods do not match"
  )

  for (metric in c("NSE", "KGE.2009")) {
    delta <- calculated[[metric]] - archived[[metric]][ix]

    assert(
      all(is.finite(delta)) &&
        all(abs(delta) < 1e-8),
      paste("Cannot reproduce archived metric:", metric)
    )
  }

  invisible(calculated)
}

verify_global(
  prepared_d,
  file.path(daily_dir, "global_native.csv")
)

cat("PASS: daily global metrics reproduced\n")

verify_global(
  prepared_h,
  file.path(hourly_dir, "global_daily.csv")
)

cat("PASS: hourly aggregated global metrics reproduced\n")

cat("\n===== 4. STRICT CALENDAR-DAY PAIRING =====\n")

d <- prepared_d$paired
h <- prepared_h$paired

assert(
  !anyDuplicated(d$date) &&
    !anyDuplicated(h$date),
  "Duplicate calendar dates"
)

common <- merge(
  d,
  h,
  by = "date",
  suffixes = c("_daily", "_hourly"),
  sort = TRUE
)

assert(nrow(common) > 0L, "No common calendar days")

assert(
  identical(
    as.numeric(common$time_daily),
    as.numeric(common$time_hourly)
  ),
  "Paired timestamps are not identical"
)

assert(
  identical(common$qObs_daily, common$qObs_hourly),
  "Daily observations differ between the two series"
)

daily_only <- setdiff(d$date, h$date)
hourly_only <- setdiff(h$date, d$date)

cat("Daily valid dates:", nrow(d), "\n")
cat("Hourly aggregated valid dates:", nrow(h), "\n")
cat("Common dates:", nrow(common), "\n")
cat("Daily-only dates:", length(daily_only), "\n")
cat("Hourly-only dates:", length(hourly_only), "\n")

if (length(hourly_only)) {
  cat("First hourly-only dates:\n")
  print(head(hourly_only, 10L))
}

common <- common[
  is.finite(common$qObs_daily) &
    common$qObs_daily >= 0 &
    is.finite(common$qSim_daily) &
    is.finite(common$qSim_hourly),
  ,
  drop = FALSE
]

assert(nrow(common) > 0L, "No valid common observations")

cat("Common days retained:", nrow(common), "\n")
cat("PASS: identical daily observations\n")

cat("\n===== 5. PAIRED CONTINUOUS METRICS =====\n")

to_metric_input <- function(sim_col) {
  data.frame(
    time = common$time_daily,
    qObs = common$qObs_daily,
    qSim = common[[sim_col]]
  )
}

metrics_d <- calculate_metrics(
  to_metric_input("qSim_daily")
)

metrics_h <- calculate_metrics(
  to_metric_input("qSim_hourly")
)

assert(
  identical(metrics_d$period, metrics_h$period),
  "Period mismatch after paired metric calculation"
)

count_in_period <- function(x, p) {
  sum(
    x$time >= periods[[p]]$ti &
      x$time <= periods[[p]]$tf &
      is.finite(x$qObs) &
      x$qObs >= 0 &
      is.finite(x$qSim)
  )
}

n_common <- vapply(
  metrics_d$period,
  function(p) {
    sum(
      common$time_daily >= periods[[p]]$ti &
        common$time_daily <= periods[[p]]$tf
    )
  },
  integer(1)
)

continuous <- data.frame(
  basin_ID = basinID,
  experiment = experiment_name,
  fold = fold,
  zDecision = as.character(md$zDecision),
  phase = as.character(md$phase),
  model_step = as.integer(md$modelStep),
  method = method,
  period = metrics_d$period,
  n_valid_days_daily = vapply(
    metrics_d$period,
    function(p) count_in_period(d, p),
    integer(1)
  ),
  n_valid_days_hourly = vapply(
    metrics_d$period,
    function(p) count_in_period(h, p),
    integer(1)
  ),
  n_common_days = n_common,
  NSE_daily = metrics_d$NSE,
  NSE_hourly = metrics_h$NSE,
  delta_NSE = metrics_h$NSE - metrics_d$NSE,
  KGE2009_daily = metrics_d$KGE.2009,
  KGE2009_hourly = metrics_h$KGE.2009,
  delta_KGE2009 = (
    metrics_h$KGE.2009 - metrics_d$KGE.2009
  ),
  metric_period_rule = md$metric_period_rule,
  daily_evaluation_dir = daily_dir,
  hourly_evaluation_dir = hourly_dir,
  stringsAsFactors = FALSE
)

assert(
  all(continuous$n_common_days >= 10L),
  "Insufficient common days"
)

print(
  continuous[, c(
    "period",
    "n_valid_days_daily",
    "n_valid_days_hourly",
    "n_common_days",
    "NSE_daily",
    "NSE_hourly",
    "delta_NSE",
    "KGE2009_daily",
    "KGE2009_hourly",
    "delta_KGE2009"
  )],
  row.names = FALSE,
  digits = 9
)

cat("\n===== 6. PAIRED DAILY FLOOD UNITS =====\n")

read_flood <- function(file) {
  assert(file.exists(file), paste("Missing flood file:", file))

  read.csv(
    file,
    stringsAsFactors = FALSE,
    colClasses = c(
      ID = "character",
      daily_unit_id = "character"
    )
  )
}

flood_d <- read_flood(
  file.path(daily_dir, "flood_native.csv")
)

flood_h <- read_flood(
  file.path(hourly_dir, "flood_daily.csv")
)

keys <- c("ID", "period", "daily_unit_id")

context <- c(
  "first_day", "last_day", "n_events", "n_days"
)

flood_metrics <- c(
  "peak_error_pct",
  "volume_error_pct",
  "peak_lag_days"
)

flags <- c(
  "obs_peak_at_boundary",
  "sim_peak_at_boundary",
  "obs_peak_tied",
  "sim_peak_tied"
)

required <- c(
  keys, context, "valid", "reason",
  flood_metrics, flags
)

assert(
  all(required %in% names(flood_d)) &&
    all(required %in% names(flood_h)),
  "Missing flood evaluation columns"
)

make_keys <- function(x) {
  paste(x$ID, x$period, x$daily_unit_id, sep = "|")
}

key_d <- make_keys(flood_d)
key_h <- make_keys(flood_h)

assert(
  !anyNA(flood_d[, keys]) &&
    !anyNA(flood_h[, keys]) &&
    !anyDuplicated(key_d) &&
    !anyDuplicated(key_h),
  "Invalid or duplicate flood-unit keys"
)

assert(
  all(flood_d$ID == basinID) &&
    all(flood_h$ID == basinID),
  "Flood basin ID does not match metadata"
)


# Both resolutions must contain the same canonical observed flood units.
# Simulation failures are represented by invalid rows, not missing rows.
daily_only_keys <- setdiff(key_d, key_h)
hourly_only_keys <- setdiff(key_h, key_d)

if (length(daily_only_keys) || length(hourly_only_keys)) {
  stop(
    "Inconsistent flood-unit inventory: daily-only=",
    length(daily_only_keys),
    ", hourly-only=",
    length(hourly_only_keys),
    "; example daily-only=",
    paste(head(daily_only_keys, 3L), collapse = ", "),
    "; example hourly-only=",
    paste(head(hourly_only_keys, 3L), collapse = ", "),
    call. = FALSE
  )
}

flood_common <- merge(
  flood_d,
  flood_h,
  by = keys,
  suffixes = c("_daily", "_hourly"),
  all = FALSE,
  sort = TRUE
)

assert(nrow(flood_common) > 0L, "No common flood units")

for (field in context) {
  assert(
    identical(
      as.character(flood_common[[paste0(field, "_daily")]]),
      as.character(flood_common[[paste0(field, "_hourly")]])
    ),
    paste("Flood-unit definition mismatch:", field)
  )
}

assert(
  !anyNA(flood_common$valid_daily) &&
    !anyNA(flood_common$valid_hourly),
  "Missing flood validity flags"
)

paired_valid <- (
  flood_common$valid_daily &
    flood_common$valid_hourly
)

for (metric in c("peak_error_pct", "volume_error_pct")) {
  for (mode in c("daily", "hourly")) {
    values <- flood_common[[paste0(metric, "_", mode)]]

    assert(
      all(is.finite(values[paired_valid])),
      paste("Non-finite valid flood metric:", metric, mode)
    )
  }
}

flood <- data.frame(
  basin_ID = basinID,
  experiment = experiment_name,
  fold = fold,
  zDecision = as.character(md$zDecision),
  phase = as.character(md$phase),
  model_step = as.integer(md$modelStep),
  method = method,
  ID = flood_common$ID,
  period = flood_common$period,
  daily_unit_id = flood_common$daily_unit_id,
  first_day = flood_common$first_day_daily,
  last_day = flood_common$last_day_daily,
  n_events = flood_common$n_events_daily,
  n_days = flood_common$n_days_daily,
  valid_daily = flood_common$valid_daily,
  valid_hourly = flood_common$valid_hourly,
  paired_valid = paired_valid,
  reason_daily = flood_common$reason_daily,
  reason_hourly = flood_common$reason_hourly,
  stringsAsFactors = FALSE
)

for (field in c(flood_metrics, flags)) {
  for (mode in c("daily", "hourly")) {
    name <- paste0(field, "_", mode)
    flood[[name]] <- flood_common[[name]]
  }
}

flood$daily_evaluation_dir <- daily_dir
flood$hourly_evaluation_dir <- hourly_dir

flood <- flood[
  order(flood$period, flood$daily_unit_id),
  ,
  drop = FALSE
]

cat("Daily flood units:", nrow(flood_d), "\n")
cat("Hourly aggregated flood units:", nrow(flood_h), "\n")
cat("Common flood units:", nrow(flood), "\n")

cat(
  "Daily-only units:",
  length(setdiff(key_d, key_h)),
  "\n"
)

cat(
  "Hourly-only units:",
  length(setdiff(key_h, key_d)),
  "\n"
)

cat("Paired valid units:", sum(flood$paired_valid), "\n")

cat("\nCommon flood units by period and validity:\n")
print(table(flood$period, flood$paired_valid))

cat("\n===== 7. FINAL VALIDATION =====\n")

assert(
  nrow(continuous) == length(periods),
  "Unexpected continuous table size"
)

assert(
  !anyDuplicated(flood[, keys]),
  "Duplicate flood units in final table"
)

cat("PASS: continuous performance table valid\n")
cat("PASS: paired flood table valid\n")

cat("\nContinuous table columns:\n")
print(names(continuous))

cat("\nFlood table columns:\n")
print(names(flood))

if (check_only) {

  cat("\nCHECK PASSED -- NO ANALYSIS FILES WRITTEN\n")

} else {

  if (file.exists(output_dir) || dir.exists(output_dir)) {
    stop("Analysis output already exists: ", output_dir)
  }

  parent <- dirname(output_dir)

  dir.create(
    parent,
    recursive = TRUE,
    showWarnings = FALSE
  )

  temporary <- tempfile(
    pattern = ".lse_paired_",
    tmpdir = parent
  )

  dir.create(temporary)

  on.exit({
    if (dir.exists(temporary)) {
      unlink(temporary, recursive = TRUE)
    }
  }, add = TRUE)

  write.csv(
    continuous,
    file.path(temporary, "paired_continuous_daily.csv"),
    row.names = FALSE
  )

  write.csv(
    flood,
    file.path(temporary, "paired_flood_daily.csv"),
    row.names = FALSE
  )

  if (!file.rename(temporary, output_dir)) {
    stop("Unable to publish analysis output directory")
  }

  cat("\nANALYSIS TABLES SAVED:\n")
  cat(
    file.path(output_dir, "paired_continuous_daily.csv"),
    "\n"
  )
  cat(
    file.path(output_dir, "paired_flood_daily.csv"),
    "\n"
  )
}

cat("\nPAIRED DAILY ANALYSIS COMPLETE\n")
