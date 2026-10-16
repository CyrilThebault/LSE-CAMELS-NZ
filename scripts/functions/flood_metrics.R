
compute_event_metrics <- function(
  time, qObs, qSim, timestep_seconds
) {

  stopifnot(
    inherits(time, "POSIXct"),
    length(time) == length(qObs),
    length(time) == length(qSim),
    is.finite(timestep_seconds),
    timestep_seconds > 0
  )

  n <- length(time)

  result <- data.frame(
    valid = FALSE,
    peak_error_pct = NA_real_,
    peak_lag_steps = NA_real_,
    volume_error_pct = NA_real_,
    obs_peak_at_boundary = NA,
    sim_peak_at_boundary = NA,
    obs_peak_tied = NA,
    sim_peak_tied = NA
  )

  if (n < 1L) return(result)

  # Require finite discharge values and a regular time grid.
  if (
    any(!is.finite(qObs)) ||
    any(!is.finite(qSim)) ||
    any(qObs < 0) ||
    any(qSim < 0) ||
    (
      n >= 2L &&
      any(diff(as.numeric(time)) != timestep_seconds)
    )
  ) {
    return(result)
  }

  if (sum(qObs) <= 0 || max(qObs) <= 0) {
    return(result)
  }

  io <- which.max(qObs)
  is <- which.max(qSim)

  result$valid <- TRUE

  result$peak_error_pct <-
    100 * (qSim[is] / qObs[io] - 1)

  result$volume_error_pct <-
    100 * (sum(qSim) / sum(qObs) - 1)

  # Lag is not informative for a single time step.
  if (n >= 2L) {
    result$peak_lag_steps <-
      as.numeric(
        difftime(
          time[is], time[io],
          units = "secs"
        )
      ) / timestep_seconds
  }

  result$obs_peak_at_boundary <-
    io == 1L || io == n

  result$sim_peak_at_boundary <-
    is == 1L || is == n

  # Multiple equal maxima can make peak timing ambiguous.
  result$obs_peak_tied <-
    sum(qObs == max(qObs)) > 1L

  result$sim_peak_tied <-
    sum(qSim == max(qSim)) > 1L

  result
}

# ==================================================
