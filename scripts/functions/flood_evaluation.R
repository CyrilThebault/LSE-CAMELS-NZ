evaluate_daily_flood_units <- function(
  paired,
  units,
  basin_id,
  evaluation_start,
  evaluation_end,
  timezone = "Etc/GMT-12"
) {

  required_paired <- c("date", "time", "qObs", "qh", "qd")
  required_units <- c(
    "ID", "daily_unit_id", "first_day",
    "last_day", "n_events", "n_days"
  )

  stopifnot(
    all(required_paired %in% names(paired)),
    all(required_units %in% names(units)),
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
      peak_error_h_pct = NA_real_,
      peak_error_d_pct = NA_real_,
      volume_error_h_pct = NA_real_,
      volume_error_d_pct = NA_real_,
      peak_lag_h_days = NA_real_,
      peak_lag_d_days = NA_real_,
      boundary_h = NA,
      boundary_d = NA
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

    h <- compute_event_metrics(
      w$time,
      w$qObs,
      w$qh,
      timestep_seconds = 86400
    )

    d <- compute_event_metrics(
      w$time,
      w$qObs,
      w$qd,
      timestep_seconds = 86400
    )

    if (!isTRUE(h$valid) || !isTRUE(d$valid)) {
      result$reason <- "invalid_discharge"
      return(result)
    }

    result$valid <- TRUE
    result$reason <- "ok"

    result$peak_error_h_pct <- h$peak_error_pct
    result$peak_error_d_pct <- d$peak_error_pct

    result$volume_error_h_pct <- h$volume_error_pct
    result$volume_error_d_pct <- d$volume_error_pct

    result$peak_lag_h_days <- h$peak_lag_steps
    result$peak_lag_d_days <- d$peak_lag_steps

    result$boundary_h <- h$sim_peak_at_boundary
    result$boundary_d <- d$sim_peak_at_boundary

    result
  }

  do.call(
    rbind,
    lapply(seq_len(nrow(u)), evaluate_one)
  )
}
