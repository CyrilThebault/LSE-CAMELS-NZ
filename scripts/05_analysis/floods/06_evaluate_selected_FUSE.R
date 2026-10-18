args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 10L) {
  stop(paste(
    "Usage: <basinID> <emulator> <qsim_hourly.rds> <qsim_daily.rds>",
    "<daily_units.csv> <hourly_catalogue.csv>",
    "<hourly_config.R> <daily_config.R> <output_dir> <dirMain>"
  ))
}

id <- as.character(args[1])
emulator <- args[2]
file_h <- normalizePath(args[3], mustWork = TRUE)
file_d <- normalizePath(args[4], mustWork = TRUE)
units_file <- normalizePath(args[5], mustWork = TRUE)
catalogue_file <- normalizePath(args[6], mustWork = TRUE)
config_h <- normalizePath(args[7], mustWork = TRUE)
config_d <- normalizePath(args[8], mustWork = TRUE)
out_dir <- path.expand(args[9])
dirMain <- normalizePath(args[10], mustWork = TRUE)

stopifnot(grepl("^[0-9]+$", id), nzchar(emulator))

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/flood_metrics.R"))
source(file.path(dirMain, "scripts/functions/evaluation_series.R"))
source(file.path(dirMain, "scripts/functions/flood_evaluation.R"))

exp_h <- load_workflow_config(config_h)
exp_d <- load_workflow_config(config_d)

stopifnot(
  identical(exp_h$timestep, "hourly"),
  identical(exp_d$timestep, "daily"),
  identical(exp_h$timezone, exp_d$timezone),
  emulator %in% exp_h$emulators,
  emulator %in% exp_d$emulators,
  !file.exists(out_dir),
  !dir.exists(out_dir)
)

# Validate simulation structure without fixed series lengths.
read_sim <- function(path, experiment) {
  sim <- readRDS(path)
  dt <- get_timestep_info(experiment)$seconds_per_timestep

  stopifnot(
    is.data.frame(sim),
    all(c("time", "qSim") %in% names(sim)),
    inherits(sim$time, "POSIXct"),
    nrow(sim) >= 2L,
    all(is.finite(as.numeric(sim$time))),
    all(is.finite(sim$qSim)),
    !anyDuplicated(sim$time),
    all(abs(diff(as.numeric(sim$time)) - dt) < 1e-6)
  )
  sim
}

sim_h <- read_sim(file_h, exp_h)
sim_d <- read_sim(file_d, exp_d)

obs_h <- read_qobs(
  file.path(project_paths(dirMain, exp_h)$forcings,
            id, paste0(id, "_input.nc")),
  exp_h
)

obs_d <- read_qobs(
  file.path(project_paths(dirMain, exp_d)$forcings,
            id, paste0(id, "_input.nc")),
  exp_d
)

# ==================================================
# Paired daily comparison
# ==================================================

prepared <- prepare_daily_comparison(
  qobs_daily = obs_d,
  qsim_hourly = sim_h,
  qsim_daily = sim_d,
  timezone = exp_d$timezone
)

paired <- prepared$paired

cat("\n===== PAIRED DAILY SERIES =====\n")
print(prepared$diagnostics)
cat("Date range:\n")
print(range(paired$date))

# ==================================================
# 4. Global metrics on common daily support
# ==================================================

periods <- metric_periods_from_config(exp_d)

common_obs <- data.frame(
  time = paired$time,
  qObs = paired$qObs
)

metrics_h <- compute_flow_metrics(
  data.frame(time = paired$time, qSim = paired$qh),
  common_obs, id, periods
)

metrics_d <- compute_flow_metrics(
  data.frame(time = paired$time, qSim = paired$qd),
  common_obs, id, periods
)

stopifnot(
  !is.null(metrics_h),
  !is.null(metrics_d)
)

global <- rbind(
  data.frame(simulation = "hourly_aggregated", metrics_h),
  data.frame(simulation = "daily", metrics_d)
)

cat("\n===== GLOBAL DAILY COMPARISON =====\n")
print(global[, c(
  "simulation", "period", "KGE.2009", "NSE",
  "alpha", "beta", "r"
)], row.names = FALSE)

# Native hourly global metrics: separate analysis
native_global <- compute_flow_metrics(
  sim_h,
  obs_h,
  id,
  metric_periods_from_config(exp_h)
)

stopifnot(!is.null(native_global))

cat("\n===== NATIVE HOURLY GLOBAL METRICS =====\n")
print(native_global[, c(
  "period", "KGE.2009", "NSE"
)], row.names = FALSE)

# ==================================================
# 5. Daily flood units
# ==================================================

units <- read.csv(
  units_file,
  stringsAsFactors = FALSE
)

daily_events <- evaluate_daily_flood_units(
  paired = paired,
  units = units,
  basin_id = id,
  evaluation_start = exp_h$evaluation_start,
  evaluation_end = exp_h$evaluation_end,
  timezone = exp_h$timezone
)

cat("\n===== DAILY FLOOD UNITS =====\n")
cat("Units:", nrow(daily_events), "\n")
cat("Valid:", sum(daily_events$valid), "\n")
cat("Invalid:", sum(!daily_events$valid), "\n")
cat("Hourly events represented:",
    sum(daily_events$n_events), "\n")
print(table(daily_events$reason))

# ==================================================
# 6. Native hourly flood events
# ==================================================

catalogue <- read.csv(
  catalogue_file,
  stringsAsFactors = FALSE
)

hourly_events <- evaluate_hourly_flood_events(
  qobs_hourly = obs_h,
  qsim_hourly = sim_h,
  events = catalogue,
  basin_id = id,
  evaluation_start = exp_h$evaluation_start,
  evaluation_end = exp_h$evaluation_end,
  timezone = exp_h$timezone
)

cat("\n===== NATIVE HOURLY FLOOD EVENTS =====\n")
cat("Events:", nrow(hourly_events), "\n")
cat("Valid:", sum(hourly_events$valid), "\n")
cat("Invalid:", sum(!hourly_events$valid), "\n")
print(table(hourly_events$reason))

# ==================================================
# 7. Summaries
# ==================================================

median_abs <- function(x) {
  if (!length(x) || all(is.na(x))) return(NA_real_)
  median(abs(x), na.rm = TRUE)
}

d <- daily_events[daily_events$valid, , drop = FALSE]
h <- hourly_events[hourly_events$valid, , drop = FALSE]

daily_summary <- data.frame(
  metric = c("Peak error [%]", "Volume error [%]", "Peak lag [days]"),
  hourly_aggregated = c(
    median_abs(d$peak_error_h_pct),
    median_abs(d$volume_error_h_pct),
    median_abs(d$peak_lag_h_days)
  ),
  daily = c(
    median_abs(d$peak_error_d_pct),
    median_abs(d$volume_error_d_pct),
    median_abs(d$peak_lag_d_days)
  )
)

hourly_summary <- data.frame(
  metric = c("Peak error [%]", "Volume error [%]", "Peak lag [h]"),
  hourly_native = c(
    median_abs(h$peak_error_pct),
    median_abs(h$volume_error_pct),
    median_abs(h$peak_lag_h)
  )
)

cat("\n===== DAILY FLOOD COMPARISON =====\n")
print(daily_summary, row.names = FALSE)

cat("\n===== NATIVE HOURLY FLOOD SUMMARY =====\n")
print(hourly_summary, row.names = FALSE)

cat("\n===== BOUNDARY PEAKS =====\n")
cat("Daily hourly-aggregated:",
    sum(d$boundary_h), "\n")
cat("Daily FUSE:",
    sum(d$boundary_d), "\n")
cat("Native hourly:",
    sum(h$sim_peak_at_boundary), "\n")

# ==================================================
# 8. Save evaluated results
# ==================================================

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

provenance <- data.frame(
  ID = id,
  emulator = emulator,
  qsim_hourly_file = file_h,
  qsim_daily_file = file_d,
  config_hourly = config_h,
  config_daily = config_d,
  daily_units_file = units_file,
  hourly_catalogue_file = catalogue_file
)

write.csv(
  global,
  file.path(out_dir, "global_daily_metrics.csv"),
  row.names = FALSE
)

write.csv(
  native_global,
  file.path(out_dir, "global_hourly_native_metrics.csv"),
  row.names = FALSE
)

write.csv(
  daily_events,
  file.path(out_dir, "flood_daily_metrics.csv"),
  row.names = FALSE
)

write.csv(
  hourly_events,
  file.path(out_dir, "flood_hourly_metrics.csv"),
  row.names = FALSE
)

write.csv(
  daily_summary,
  file.path(out_dir, "flood_daily_summary.csv"),
  row.names = FALSE
)

write.csv(
  hourly_summary,
  file.path(out_dir, "flood_hourly_summary.csv"),
  row.names = FALSE
)

write.csv(
  prepared$diagnostics,
  file.path(out_dir, "series_diagnostics.csv"),
  row.names = FALSE
)

write.csv(
  provenance,
  file.path(out_dir, "provenance.csv"),
  row.names = FALSE
)

cat("\n===== OUTPUT DIRECTORY =====\n")
cat(out_dir, "\n")

cat("\nFUSE EVALUATION COMPLETE\n")
