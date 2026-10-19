args <- commandArgs(trailingOnly = TRUE)

if (length(args) > 1L || (length(args) == 1L && args[1] != "--force")) {
  stop("Usage: Rscript 05_build_observed_flood_daily_units.R [--force]")
}

force <- length(args) == 1L

source("scripts/functions/common.R")

exp <- load_workflow_config("config/experiment_hourly.R")
tz <- exp$timezone

input <- "data/flood/qc/observed_flood_catalogue_reviewed.csv"

output_dir <- Sys.getenv(
  "FLOOD_DAILY_OUTPUT_DIR",
  unset = file.path("data", "flood", "qc")
)

out_units <- file.path(output_dir, "observed_flood_daily_units.csv")
out_mapping <- file.path(output_dir, "observed_flood_daily_event_mapping.csv")

existing <- c(out_units, out_mapping)
existing <- existing[file.exists(existing)]

if (length(existing) && !force) {
  stop(
    "Existing daily flood output(s):\n",
    paste(existing, collapse = "\n"),
    "\nUse --force to explicitly allow recalculation."
  )
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# ==================================================
# 1. Read canonical hourly catalogue
# ==================================================

events <- read.csv(
  input,
  stringsAsFactors = FALSE
)

required <- c(
  "ID", "event_id", "analysis_eligible",
  "start_time", "end_time"
)

stopifnot(all(required %in% names(events)))

eligible <- !is.na(events$analysis_eligible) &
  as.logical(events$analysis_eligible)

events <- events[which(eligible), , drop = FALSE]

stopifnot(
  nrow(events) > 0L,
  !anyDuplicated(events$event_id)
)

parse_time <- function(x) {
  as.POSIXct(
    x,
    format = "%Y-%m-%d %H:%M:%S",
    tz = tz
  )
}

start <- parse_time(events$start_time)
end <- parse_time(events$end_time)

stopifnot(
  !anyNA(start),
  !anyNA(end),
  all(end >= start),
  all(format(start, "%M:%S", tz = tz) == "30:00"),
  all(format(end, "%M:%S", tz = tz) == "30:00")
)

# ==================================================
# 2. Sort events chronologically within basins
# ==================================================

basin <- as.character(events$ID)

ord <- order(
  basin,
  as.numeric(start),
  as.numeric(end),
  events$event_id
)

events <- events[ord, , drop = FALSE]
basin <- basin[ord]
start <- start[ord]
end <- end[ord]

n <- nrow(events)

# Convert timestamps to NZST calendar days
first_day <- as.integer(as.Date(
  format(start, "%Y-%m-%d", tz = tz)
))

last_day <- as.integer(as.Date(
  format(end, "%Y-%m-%d", tz = tz)
))

duration_h <- as.integer(round(
  as.numeric(difftime(end, start, units = "hours"))
)) + 1L

stopifnot(
  all(duration_h >= 1L),
  all(last_day >= first_day)
)

# ==================================================
# 3. Group events sharing calendar days
# ==================================================

# Preallocate one possible group per event
group <- integer(n)

u_basin <- character(n)
u_first <- integer(n)
u_last <- integer(n)
u_n_events <- integer(n)
u_hours <- numeric(n)

g <- 0L

for (i in seq_len(n)) {

  new_group <- (
    i == 1L ||
    basin[i] != basin[i - 1L] ||
    first_day[i] > u_last[g]
  )

  if (new_group) {

    g <- g + 1L

    u_basin[g] <- basin[i]
    u_first[g] <- first_day[i]
    u_last[g] <- last_day[i]

  } else {

    # Extend the current group if necessary
    u_last[g] <- max(
      u_last[g],
      last_day[i]
    )
  }

  group[i] <- g

  u_n_events[g] <- u_n_events[g] + 1L
  u_hours[g] <- u_hours[g] + duration_h[i]
}

# ==================================================
# 4. Build daily evaluation units
# ==================================================

ix <- seq_len(g)

first_date <- as.Date(
  u_first[ix],
  origin = "1970-01-01"
)

last_date <- as.Date(
  u_last[ix],
  origin = "1970-01-01"
)

n_days <- u_last[ix] - u_first[ix] + 1L

unit_id <- paste0(
  u_basin[ix],
  "_D",
  format(first_date, "%Y%m%d")
)

units <- data.frame(
  daily_unit_id = unit_id,
  ID = u_basin[ix],
  first_day = first_date,
  last_day = last_date,
  n_events = u_n_events[ix],
  n_days = n_days,
  event_hours = u_hours[ix],
  window_hours = 24L * n_days,
  hourly_coverage = u_hours[ix] / (24 * n_days)
)

# ==================================================
# 5. Build hourly-to-daily correspondence
# ==================================================

mapping <- data.frame(
  ID = basin,
  event_id = events$event_id,
  daily_unit_id = unit_id[group],
  start_time = events$start_time,
  end_time = events$end_time,
  duration_h = duration_h
)

# ==================================================
# 6. Consistency checks
# ==================================================

stopifnot(
  nrow(mapping) == n,
  nrow(units) == g,
  !anyDuplicated(mapping$event_id),
  !anyDuplicated(units$daily_unit_id),
  all(mapping$daily_unit_id %in% units$daily_unit_id),
  sum(units$n_events) == n,
  all(units$n_days >= 1L),
  all(units$hourly_coverage > 0),
  all(units$hourly_coverage <= 1 + 1e-10)
)

# Expected values from our previous diagnostics
stopifnot(
  n == 34852L,
  g == 31347L,
  sum(units$n_events == 1L) == 28361L,
  sum(units$n_events > 1L) == 2986L,
  sum(units$n_events[units$n_events > 1L]) == 6491L,
  sum(units$n_days == 1L) == 96L
)

# ==================================================
# 7. Report
# ==================================================

cat("\n===== DAILY UNIT GENERATION =====\n")
cat("Timezone:", tz, "\n")
cat("Eligible hourly events:", n, "\n")
cat("Daily units:", g, "\n")
cat("Basins:", length(unique(units$ID)), "\n")

cat("\n===== UNIT COMPOSITION =====\n")
print(table(units$n_events))

cat("\n===== DAILY WINDOW COVERAGE =====\n")
print(quantile(
  100 * units$hourly_coverage,
  probs = c(0, 0.1, 0.25, 0.5, 0.75, 0.9, 1)
))

cat("\n===== BASIN 33301 =====\n")

example <- units[
  units$ID == "33301",
  ,
  drop = FALSE
]

cat("Daily units:", nrow(example), "\n")
cat("Multi-event units:",
    sum(example$n_events > 1L), "\n")

print(
  head(example, 5),
  row.names = FALSE
)

# ==================================================
# 8. Save only after successful validation
# ==================================================

write.csv(
  units,
  out_units,
  row.names = FALSE
)

write.csv(
  mapping,
  out_mapping,
  row.names = FALSE
)

cat("\n===== OUTPUTS =====\n")
cat("Units:", out_units, "\n")
cat("Mapping:", out_mapping, "\n")

cat("\nDAILY UNIT GENERATION COMPLETE\n")
