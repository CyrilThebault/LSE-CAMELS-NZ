prepare_daily_comparison <- function(
  qobs_daily,
  qsim_hourly,
  qsim_daily,
  timezone = "Etc/GMT-12"
) {

  # --------------------------------------------
  # 1. Validate inputs
  # --------------------------------------------

  check_series <- function(x, value, label) {

    if (!all(c("time", value) %in% names(x))) {
      stop(label, ": missing columns")
    }

    if (!inherits(x$time, "POSIXct")) {
      stop(label, ": time must be POSIXct")
    }

    if (!is.numeric(x[[value]])) {
      stop(label, ": discharge must be numeric")
    }

    if (
      nrow(x) == 0L ||
      anyNA(x$time) ||
      anyDuplicated(x$time)
    ) {
      stop(label, ": empty or invalid time axis")
    }
  }

  check_series(qobs_daily, "qObs", "qobs_daily")
  check_series(qsim_hourly, "qSim", "qsim_hourly")
  check_series(qsim_daily, "qSim", "qsim_daily")

  nz_date <- function(t) {
    as.Date(format(t, "%Y-%m-%d", tz = timezone))
  }

  nz_noon <- function(d) {
    as.POSIXct(
      paste(d, "12:00:00"),
      tz = timezone
    )
  }

  # --------------------------------------------
  # 2. Validate daily timestamps
  # --------------------------------------------

  obs_dates <- nz_date(qobs_daily$time)
  sim_dates <- nz_date(qsim_daily$time)

  if (
    anyDuplicated(obs_dates) ||
    anyDuplicated(sim_dates)
  ) {
    stop("Duplicate daily dates")
  }

  if (
    !identical(
      as.numeric(qobs_daily$time),
      as.numeric(nz_noon(obs_dates))
    ) ||
    !identical(
      as.numeric(qsim_daily$time),
      as.numeric(nz_noon(sim_dates))
    )
  ) {
    stop("Daily timestamps must be at 12:00 NZST")
  }

  # --------------------------------------------
  # 3. Aggregate hourly simulation
  # --------------------------------------------

  h <- qsim_hourly[
    order(qsim_hourly$time),
    ,
    drop = FALSE
  ]

  day_keys <- format(
    h$time,
    "%Y-%m-%d",
    tz = timezone
  )

  groups <- split(seq_len(nrow(h)), day_keys)
  dates <- names(groups)

  qh <- vapply(
    seq_along(groups),
    function(j) {

      ix <- groups[[j]]

      if (length(ix) != 24L) {
        return(NA_real_)
      }

      # Require exactly 00:30, 01:30, ..., 23:30
      expected <- as.POSIXct(
        paste(dates[j], "00:30:00"),
        tz = timezone
      ) + (0:23) * 3600

      if (!identical(
        as.numeric(h$time[ix]),
        as.numeric(expected)
      )) {
        return(NA_real_)
      }

      q <- h$qSim[ix]

      if (!all(is.finite(q))) {
        return(NA_real_)
      }

      sum(q)
    },
    numeric(1)
  )

  hourly_daily <- data.frame(
    date = as.Date(dates),
    qh = as.numeric(qh)
  )

  # --------------------------------------------
  # 4. Prepare daily series
  # --------------------------------------------

  observed <- data.frame(
    date = obs_dates,
    qObs = qobs_daily$qObs
  )

  daily_sim <- data.frame(
    date = sim_dates,
    qd = qsim_daily$qSim
  )

  # --------------------------------------------
  # 5. Strictly common daily support
  # --------------------------------------------

  joined <- Reduce(
    function(a, b) merge(a, b, by = "date"),
    list(observed, hourly_daily, daily_sim)
  )

  complete <- (
    is.finite(joined$qObs) &
    is.finite(joined$qh) &
    is.finite(joined$qd)
  )

  paired <- joined[complete, , drop = FALSE]
  paired <- paired[order(paired$date), , drop = FALSE]

  if (
    nrow(paired) == 0L ||
    anyDuplicated(paired$date)
  ) {
    stop("No valid paired daily observations")
  }

  paired$time <- nz_noon(paired$date)

  # --------------------------------------------
  # 6. Diagnostics
  # --------------------------------------------

  diagnostics <- data.frame(
    qobs_days = nrow(observed),
    hourly_days = nrow(hourly_daily),
    hourly_complete_days = sum(is.finite(qh)),
    daily_sim_days = nrow(daily_sim),
    calendar_overlap_days = nrow(joined),
    valid_paired_days = nrow(paired)
  )

  list(
    paired = paired,
    diagnostics = diagnostics
  )
}
