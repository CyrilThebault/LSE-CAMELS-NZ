# ==============================================================================
# Prepare daily observations and one FUSE simulation for evaluation
# ==============================================================================

prepare_daily_evaluation <- function(
  qobs_daily,
  qsim,
  simulation_timestep,
  timezone = "Etc/GMT-12"
) {

  stopifnot(
    simulation_timestep %in% c("hourly", "daily"),
    all(c("time", "qObs") %in% names(qobs_daily)),
    all(c("time", "qSim") %in% names(qsim)),
    inherits(qobs_daily$time, "POSIXct"),
    inherits(qsim$time, "POSIXct"),
    is.numeric(qobs_daily$qObs),
    is.numeric(qsim$qSim),
    nrow(qobs_daily) > 0L,
    nrow(qsim) > 0L,
    !anyNA(qobs_daily$time),
    !anyNA(qsim$time),
    !anyDuplicated(qobs_daily$time),
    !anyDuplicated(qsim$time)
  )

  nz_date <- function(t) {
    as.Date(format(t, "%Y-%m-%d", tz = timezone))
  }

  nz_noon <- function(d) {
    as.POSIXct(paste(d, "12:00:00"), tz = timezone)
  }

  obs_dates <- nz_date(qobs_daily$time)

  stopifnot(
    !anyDuplicated(obs_dates),
    identical(
      as.numeric(qobs_daily$time),
      as.numeric(nz_noon(obs_dates))
    )
  )

  observed <- data.frame(
    date = obs_dates,
    qObs = qobs_daily$qObs
  )

  if (simulation_timestep == "daily") {

    sim_dates <- nz_date(qsim$time)

    stopifnot(
      !anyDuplicated(sim_dates),
      identical(
        as.numeric(qsim$time),
        as.numeric(nz_noon(sim_dates))
      )
    )

    simulated <- data.frame(
      date = sim_dates,
      qSim = qsim$qSim
    )

  } else {

    h <- qsim[order(qsim$time), , drop = FALSE]

    day_keys <- format(h$time, "%Y-%m-%d", tz = timezone)
    groups <- split(seq_len(nrow(h)), day_keys)
    dates <- names(groups)

    values <- vapply(seq_along(groups), function(j) {

      ix <- groups[[j]]

      if (length(ix) != 24L) {
        return(NA_real_)
      }

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

      if (!all(is.finite(h$qSim[ix]))) {
        return(NA_real_)
      }

      sum(h$qSim[ix])

    }, numeric(1))

    simulated <- data.frame(
      date = as.Date(dates),
      qSim = as.numeric(values)
    )
  }

  joined <- merge(observed, simulated, by = "date")

  complete <- (
    is.finite(joined$qObs) &
    is.finite(joined$qSim)
  )

  paired <- joined[complete, , drop = FALSE]
  paired <- paired[order(paired$date), , drop = FALSE]

  if (!nrow(paired)) {
    stop("No valid paired daily observations")
  }

  paired$time <- nz_noon(paired$date)

  diagnostics <- data.frame(
    qobs_days = nrow(observed),
    simulated_days = nrow(simulated),
    simulated_complete_days = sum(is.finite(simulated$qSim)),
    calendar_overlap_days = nrow(joined),
    valid_paired_days = nrow(paired)
  )

  list(
    paired = paired,
    diagnostics = diagnostics
  )
}
