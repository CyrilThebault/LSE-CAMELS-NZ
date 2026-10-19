evaluate_daily_flood_units <- function(
  paired,
  units,
  basin_id,
  evaluation_start,
  evaluation_end,
  timezone = "Etc/GMT-12"
) {

  required_paired <- c("date", "time", "qObs", "qSim")
  required_units <- c(
    "ID", "daily_unit_id", "first_day",
    "last_day", "n_events", "n_days"
  )

  stopifnot(
    all(required_paired %in% names(paired)),
    all(required_units %in% names(units)),
    inherits(paired$time, "POSIXct"),
    !anyDuplicated(paired$date),
    !anyDuplicated(units$daily_unit_id)
  )

  paired <- paired[order(paired$date), , drop = FALSE]
  paired$date <- as.Date(paired$date)

  u <- units[
    as.character(units$ID) == as.character(basin_id),
    ,
    drop = FALSE
  ]

  u$first_day <- as.Date(u$first_day)
  u$last_day <- as.Date(u$last_day)

  # Require the entire daily unit to lie within
  # the configured evaluation period.
  first_time <- as.POSIXct(
    paste(u$first_day, "00:30:00"),
    tz = timezone
  )

  last_time <- as.POSIXct(
    paste(u$last_day, "23:30:00"),
    tz = timezone
  )

  eligible <- (
    first_time >= evaluation_start &
    last_time <= evaluation_end
  )

  u <- u[eligible, , drop = FALSE]

  if (!nrow(u)) {
    stop("No daily flood units in the evaluation period")
  }

  evaluate_one <- function(i) {

    ev <- u[i, , drop = FALSE]

    days <- seq(
      ev$first_day,
      ev$last_day,
      by = "day"
    )

    ix <- match(days, paired$date)

    result <- data.frame(
      ID = as.character(basin_id),
      daily_unit_id = ev$daily_unit_id,
      first_day = ev$first_day,
      last_day = ev$last_day,
      n_events = ev$n_events,
      n_days = ev$n_days,
      valid = FALSE,
      reason = NA_character_,
      peak_error_pct = NA_real_,
      volume_error_pct = NA_real_,
      peak_lag_days = NA_real_,
      obs_peak_at_boundary = NA,
      sim_peak_at_boundary = NA,
      obs_peak_tied = NA,
      sim_peak_tied = NA
    )

    # Never evaluate a partially available event window.
    if (anyNA(ix)) {
      result$reason <- "missing_paired_days"
      return(result)
    }

    w <- paired[ix, , drop = FALSE]

    if (
      nrow(w) != ev$n_days ||
      !identical(as.Date(w$date), as.Date(days))
    ) {
      result$reason <- "incomplete_window"
      return(result)
    }

    metrics <- compute_event_metrics(
      time = w$time,
      qObs = w$qObs,
      qSim = w$qSim,
      timestep_seconds = 86400
    )

    if (!isTRUE(metrics$valid)) {
      result$reason <- "invalid_discharge"
      return(result)
    }

    result$valid <- TRUE
    result$reason <- "ok"

    result$peak_error_pct <- metrics$peak_error_pct
    result$volume_error_pct <- metrics$volume_error_pct
    result$peak_lag_days <- metrics$peak_lag_steps

    result$obs_peak_at_boundary <-
      metrics$obs_peak_at_boundary

    result$sim_peak_at_boundary <-
      metrics$sim_peak_at_boundary

    result$obs_peak_tied <- metrics$obs_peak_tied
    result$sim_peak_tied <- metrics$sim_peak_tied

    result
  }

  do.call(
    rbind,
    lapply(seq_len(nrow(u)), evaluate_one)
  )
}


evaluate_hourly_flood_events <- function(
  qobs_hourly,
  qsim_hourly,
  events,
  basin_id,
  evaluation_start,
  evaluation_end,
  timezone = "Etc/GMT-12"
) {

  stopifnot(
    all(c("time", "qObs") %in% names(qobs_hourly)),
    all(c("time", "qSim") %in% names(qsim_hourly)),
    all(c(
      "ID", "event_id", "analysis_eligible",
      "start_time", "end_time"
    ) %in% names(events)),
    inherits(qobs_hourly$time, "POSIXct"),
    inherits(qsim_hourly$time, "POSIXct"),
    !anyDuplicated(qobs_hourly$time),
    !anyDuplicated(qsim_hourly$time)
  )

  eligible <- (
    as.character(events$ID) == as.character(basin_id) &
    !is.na(events$analysis_eligible) &
    as.logical(events$analysis_eligible)
  )

  e <- events[eligible, , drop = FALSE]

  parse_time <- function(x) {
    as.POSIXct(
      x,
      format = "%Y-%m-%d %H:%M:%S",
      tz = timezone
    )
  }

  start <- parse_time(e$start_time)
  end <- parse_time(e$end_time)

  stopifnot(!anyNA(start), !anyNA(end), all(end >= start))

  within_period <- (
    start >= evaluation_start &
    end <= evaluation_end
  )

  e <- e[within_period, , drop = FALSE]
  start <- start[within_period]
  end <- end[within_period]

  if (!nrow(e)) {
    stop("No eligible hourly events in evaluation period")
  }

  stopifnot(!anyDuplicated(e$event_id))

  # Preserve missing observations/simulations.
  # Never discard individual hours before checking event windows.
  aligned <- merge(
    qobs_hourly[, c("time", "qObs")],
    qsim_hourly[, c("time", "qSim")],
    by = "time",
    all = TRUE,
    sort = TRUE
  )

  aligned_time <- as.numeric(aligned$time)

  evaluate_one <- function(i) {

    expected <- seq(
      start[i],
      end[i],
      by = "hour"
    )

    stopifnot(
      as.numeric(tail(expected, 1)) ==
        as.numeric(end[i])
    )

    result <- data.frame(
      ID = as.character(basin_id),
      event_id = e$event_id[i],
      start_time = start[i],
      end_time = end[i],
      n_hours = length(expected),
      valid = FALSE,
      reason = NA_character_,
      peak_error_pct = NA_real_,
      volume_error_pct = NA_real_,
      peak_lag_h = NA_real_,
      obs_peak_at_boundary = NA,
      sim_peak_at_boundary = NA,
      obs_peak_tied = NA,
      sim_peak_tied = NA
    )

    ix <- match(
      as.numeric(expected),
      aligned_time
    )

    if (anyNA(ix)) {
      result$reason <- "missing_hourly_timestamps"
      return(result)
    }

    w <- aligned[ix, , drop = FALSE]

    metrics <- compute_event_metrics(
      time = w$time,
      qObs = w$qObs,
      qSim = w$qSim,
      timestep_seconds = 3600
    )

    if (!isTRUE(metrics$valid)) {
      result$reason <- "invalid_discharge"
      return(result)
    }

    result$valid <- TRUE
    result$reason <- "ok"

    result$peak_error_pct <- metrics$peak_error_pct
    result$volume_error_pct <- metrics$volume_error_pct
    result$peak_lag_h <- metrics$peak_lag_steps

    result$obs_peak_at_boundary <-
      metrics$obs_peak_at_boundary

    result$sim_peak_at_boundary <-
      metrics$sim_peak_at_boundary

    result$obs_peak_tied <- metrics$obs_peak_tied
    result$sim_peak_tied <- metrics$sim_peak_tied

    result
  }

  do.call(
    rbind,
    lapply(seq_len(nrow(e)), evaluate_one)
  )
}
