library(ncdf4)
library(parallel)

args <- commandArgs(trailingOnly = TRUE)

force <- length(args) > 0L && tail(args, 1L) == "--force"
if (force) args <- head(args, -1L)

if (length(args) > 1L) {
  stop("Usage: Rscript 03_screen_observed_flood_qc.R [dirMain] [--force]")
}
dirMain <- if (length(args)) {
  normalizePath(args[1], mustWork = TRUE)
} else {
  normalizePath(".", mustWork = TRUE)
}

source(file.path(dirMain, "scripts", "functions", "common.R"))

experiment <- load_workflow_config(
  file.path(dirMain, "config", "experiment_hourly.R")
)

stopifnot(
  identical(experiment$timestep, "hourly"),
  is.character(experiment$timezone),
  length(experiment$timezone) == 1L,
  !is.na(experiment$timezone),
  nzchar(experiment$timezone)
)

fileCatalogue <- file.path(
  dirMain, "data", "flood", "observed_flood_catalogue.csv"
)

dirQC <- Sys.getenv(
  "QC_OUT_DIR",
  file.path(dirMain, "data", "flood", "qc")
)
fileOut <- file.path(dirQC, "observed_flood_qc.csv")
fileReview <- file.path(dirQC, "observed_flood_qc_review.csv")

existing <- c(fileOut, fileReview)
existing <- existing[file.exists(existing)]

if (length(existing) && !force) {
  stop(
    "Existing flood QC output(s):\n",
    paste(existing, collapse = "\n"),
    "\nUse --force to explicitly allow recalculation."
  )
}

dir.create(dirQC, recursive = TRUE, showWarnings = FALSE)

NCORES <- as.integer(Sys.getenv("NCORES", "8"))
available_cores <- parallel::detectCores()
if (!is.finite(available_cores)) {
  available_cores <- NCORES
}
NCORES <- max(1L, min(NCORES, available_cores))


# ==============================================================================
# QC thresholds
# ==============================================================================

MIN_BASIN_EVENTS <- 20L

# Distance outside the basin-specific [Q10, Q90] event envelope, normalised by
# Q90 - Q10.
TIME_FAR <- 0.50
TIME_VERY_FAR <- 1.00

# Peak discharge is evaluated on log scale relative to flood peaks from the same
# basin.
PEAK_AMPLITUDE_VERY_FAR <- 1.00

PEAK_EDGE_FRACTION <- 0.10

# Sharp-peak morphology. This is diagnostic and does not trigger review alone.
SPIKE_NEIGHBOUR_RATIO <- 3
SPIKE_LOCAL_RATIO <- 3
SPIKE_MAX_WIDTH_H <- 2L

DATA_GAP_CONTEXT_H <- 24L

# A 24-h quasi-linear Qobs window is searched within 24 h before and after each
# event. A passing window must intersect the event.
LINEAR_WINDOW_H <- 24L
LINEAR_CONTEXT_H <- 24L
LINEAR_R2 <- 0.9999
LINEAR_REL_RMSE <- 0.01
LINEAR_DQ_CV <- 0.02
LINEAR_MAX_UNIQUE_DQ <- 3L

# A significant reversal requires both adjacent hourly slopes to have magnitude
# >= 1% of the event Q range. An event is flagged as noisy when at least 10 such
# reversals occur with a median temporal spacing <= 3 h.
SIGNIFICANT_SLOPE_FRACTION <- 0.01
NOISE_MIN_SIGNIFICANT_REVERSALS <- 10L
NOISE_MAX_MEDIAN_GAP_H <- 3


# ==============================================================================
# Helpers
# ==============================================================================

parse_time <- function(x) {
  as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = experiment$timezone)
}




qtl <- function(x, p) {
  x <- x[is.finite(x)]
  if (!length(x)) {
    return(NA_real_)
  }

  as.numeric(quantile(x, p, type = 7, na.rm = TRUE))
}


outside_distance <- function(x, q10, q90) {
  width <- q90 - q10
  out <- rep(NA_real_, length(x))

  ok <- is.finite(x) & is.finite(q10) & is.finite(q90) & width > 0
  out[ok] <- 0

  low <- ok & x < q10
  high <- ok & x > q90

  out[low] <- (q10[low] - x[low]) / width[low]
  out[high] <- (x[high] - q90[high]) / width[high]

  out
}


add_basin_envelope <- function(x, variable) {
  q10_name <- paste0(variable, "_q10")
  q90_name <- paste0(variable, "_q90")
  dist_name <- paste0(variable, "_q10q90_distance")

  x[[q10_name]] <- NA_real_
  x[[q90_name]] <- NA_real_

  for (ID in unique(x$ID)) {
    ii <- which(x$ID == ID)
    z <- x[[variable]][ii]
    z <- z[is.finite(z)]

    if (length(z) < MIN_BASIN_EVENTS) {
      next
    }

    x[[q10_name]][ii] <- qtl(z, 0.10)
    x[[q90_name]][ii] <- qtl(z, 0.90)
  }

  x[[dist_name]] <- outside_distance(
    x[[variable]], x[[q10_name]], x[[q90_name]]
  )

  x
}


safe_ratio <- function(a, b) {
  if (!is.finite(a) || !is.finite(b)) {
    return(NA_real_)
  }

  if (b == 0) {
    return(if (a > 0) Inf else NA_real_)
  }

  a / b
}


reversal_fraction <- function(q) {
  dq <- diff(q)
  dq <- dq[is.finite(dq) & dq != 0]

  if (length(dq) < 2L) {
    return(NA_real_)
  }

  s <- sign(dq)
  mean(s[-1L] != s[-length(s)])
}


noise_ratio <- function(q) {
  if (length(q) < 7L || any(!is.finite(q))) {
    return(NA_real_)
  }

  sm <- as.numeric(stats::filter(q, rep(1 / 5, 5), sides = 2))
  residual <- q - sm
  residual <- residual[is.finite(residual)]
  scale <- IQR(q, na.rm = TRUE, type = 7)

  if (!is.finite(scale) || scale <= 0 || !length(residual)) {
    return(NA_real_)
  }

  mad(residual, center = median(residual), constant = 1.4826) / scale
}


peak_width_50 <- function(q, k) {
  if (
    !length(q) || !is.finite(k) || k < 1L || k > length(q) ||
      !is.finite(q[k])
  ) {
    return(NA_integer_)
  }

  threshold <- 0.5 * q[k]
  left <- k
  right <- k

  while (
    left > 1L &&
      is.finite(q[left - 1L]) &&
      q[left - 1L] >= threshold
  ) {
    left <- left - 1L
  }

  while (
    right < length(q) &&
      is.finite(q[right + 1L]) &&
      q[right + 1L] >= threshold
  ) {
    right <- right + 1L
  }

  right - left + 1L
}


significant_reversal_metrics <- function(
    q,
    slope_fraction = SIGNIFICANT_SLOPE_FRACTION) {
  out <- c(
    n = NA_real_,
    density = NA_real_,
    active_fraction = NA_real_,
    median_gap_h = NA_real_,
    pair_frac_le3h = NA_real_,
    max_cluster_3h = NA_real_
  )

  q <- as.numeric(q)

  if (length(q) < 3L || any(!is.finite(q))) {
    return(out)
  }

  q_range <- diff(range(q))

  if (!is.finite(q_range) || q_range <= 0) {
    out["n"] <- 0
    out["density"] <- 0
    out["active_fraction"] <- NA_real_
    out["median_gap_h"] <- NA_real_
    out["pair_frac_le3h"] <- 0
    out["max_cluster_3h"] <- 0
    return(out)
  }

  dq <- diff(q)
  left <- dq[-length(dq)]
  right <- dq[-1L]
  valid <- is.finite(left) & is.finite(right)

  threshold <- slope_fraction * q_range
  active <- valid & abs(left) >= threshold & abs(right) >= threshold
  reversal <- active & sign(left) != sign(right)

  n_reversal <- sum(reversal)
  out["n"] <- n_reversal
  out["density"] <- if (sum(valid) > 0L) n_reversal / sum(valid) else NA_real_
  out["active_fraction"] <- if (sum(active) > 0L) {
    n_reversal / sum(active)
  } else {
    NA_real_
  }

  if (n_reversal < 2L) {
    out["median_gap_h"] <- NA_real_
    out["pair_frac_le3h"] <- 0
    out["max_cluster_3h"] <- 0
    return(out)
  }

  pos <- which(reversal) + 1L
  gaps <- diff(pos)

  out["median_gap_h"] <- median(gaps)
  out["pair_frac_le3h"] <- mean(gaps <= 3L)

  cluster <- cumsum(c(1L, gaps > 3L))
  out["max_cluster_3h"] <- max(as.integer(table(cluster)))

  out
}


tv_excess_range <- function(q) {
  q <- as.numeric(q)

  if (length(q) < 3L || any(!is.finite(q))) {
    return(NA_real_)
  }

  q_range <- diff(range(q))
  if (!is.finite(q_range) || q_range <= 0) {
    return(0)
  }

  total_variation <- sum(abs(diff(q)))
  kpeak <- which.max(q)
  minimum_variation <- abs(q[kpeak] - q[1L]) +
    abs(q[kpeak] - q[length(q)])

  max(0, total_variation - minimum_variation) / q_range
}


linear_diag <- function(q) {
  q <- as.numeric(q)

  if (length(q) < 12L || any(!is.finite(q))) {
    return(c(
      r2 = NA_real_,
      rel_rmse = NA_real_,
      dq_cv = NA_real_,
      n_unique_dq = NA_real_
    ))
  }

  t <- seq_along(q)
  slope <- cov(t, q) / var(t)
  intercept <- mean(q) - slope * mean(t)
  fitted <- intercept + slope * t
  residual <- q - fitted

  sst <- sum((q - mean(q))^2)
  sse <- sum(residual^2)
  r2 <- if (sst > 0) 1 - sse / sst else NA_real_

  q_range <- diff(range(q))
  rel_rmse <- if (q_range > 0) sqrt(mean(residual^2)) / q_range else NA_real_

  dq <- diff(q)
  dq_cv <- if (length(dq) >= 2L && abs(mean(dq)) > 0) {
    sd(dq) / abs(mean(dq))
  } else {
    NA_real_
  }

  n_unique_dq <- length(unique(signif(dq, 8)))

  c(
    r2 = r2,
    rel_rmse = rel_rmse,
    dq_cv = dq_cv,
    n_unique_dq = n_unique_dq
  )
}


linear_pass <- function(z) {
  all(
    is.finite(z),
    z["r2"] >= LINEAR_R2,
    z["rel_rmse"] <= LINEAR_REL_RMSE,
    z["dq_cv"] <= LINEAR_DQ_CV,
    z["n_unique_dq"] <= LINEAR_MAX_UNIQUE_DQ
  )
}


scan_linear_qobs <- function(q, time, k1, k2) {
  out <- list(
    flag = FALSE,
    start = NA_character_,
    end = NA_character_,
    overlap_h = NA_real_,
    r2 = NA_real_,
    rel_rmse = NA_real_,
    dq_cv = NA_real_,
    n_unique_dq = NA_real_
  )

  search_start <- max(1L, k1 - LINEAR_CONTEXT_H)
  search_end <- min(length(q), k2 + LINEAR_CONTEXT_H)
  last_start <- search_end - LINEAR_WINDOW_H

  if (last_start < search_start) {
    return(out)
  }

  best <- NULL

  for (j in seq.int(search_start, last_start)) {
    j2 <- j + LINEAR_WINDOW_H
    overlap_start <- max(j, k1)
    overlap_end <- min(j2, k2)

    if (overlap_end < overlap_start) {
      next
    }

    idx <- j:j2
    if (any(!is.finite(q[idx]))) {
      next
    }

    z <- linear_diag(q[idx])
    if (!linear_pass(z)) {
      next
    }

    overlap_h <- overlap_end - overlap_start

    if (
      is.null(best) ||
        overlap_h > best$overlap_h ||
        (
          overlap_h == best$overlap_h &&
            z["rel_rmse"] < best$diag["rel_rmse"]
        )
    ) {
      best <- list(
        start = j,
        end = j2,
        overlap_h = overlap_h,
        diag = z
      )
    }
  }

  if (is.null(best)) {
    return(out)
  }

  out$flag <- TRUE
  out$start <- format(time[best$start], "%Y-%m-%d %H:%M:%S", tz = experiment$timezone)
  out$end <- format(time[best$end], "%Y-%m-%d %H:%M:%S", tz = experiment$timezone)
  out$overlap_h <- best$overlap_h
  out$r2 <- unname(best$diag["r2"])
  out$rel_rmse <- unname(best$diag["rel_rmse"])
  out$dq_cv <- unname(best$diag["dq_cv"])
  out$n_unique_dq <- unname(best$diag["n_unique_dq"])

  out
}


# ==============================================================================
# Catalogue
# ==============================================================================

stopifnot(file.exists(fileCatalogue))

ev <- read.csv(fileCatalogue, stringsAsFactors = FALSE)
ev$ID <- as.character(ev$ID)

basin_ids <- trimws(Sys.getenv("BASIN_IDS", ""))
if (nzchar(basin_ids)) {
  basin_ids <- unique(strsplit(basin_ids, "[,[:space:]]+")[[1]])
  ev <- ev[ev$ID %in% basin_ids, , drop = FALSE]

  if (!nrow(ev)) {
    stop("No catalogue events match BASIN_IDS.")
  }
}

ev$start_posix <- parse_time(ev$start_time)
ev$peak_posix <- parse_time(ev$peak_time_obs)
ev$end_posix <- parse_time(ev$end_time)

ev$duration_calc_h <- as.numeric(
  difftime(ev$end_posix, ev$start_posix, units = "hours")
)
ev$rise_h <- as.numeric(
  difftime(ev$peak_posix, ev$start_posix, units = "hours")
)
ev$recession_h <- as.numeric(
  difftime(ev$end_posix, ev$peak_posix, units = "hours")
)

ev$peak_fraction <- ifelse(
  ev$duration_calc_h > 0,
  ev$rise_h / ev$duration_calc_h,
  NA_real_
)
ev$row_id_qc <- seq_len(nrow(ev))

for (v in c("duration_calc_h", "rise_h", "recession_h")) {
  ev <- add_basin_envelope(ev, v)
}

ev$max_time_distance <- pmax(
  ev$duration_calc_h_q10q90_distance,
  ev$rise_h_q10q90_distance,
  ev$recession_h_q10q90_distance,
  na.rm = TRUE
)
ev$max_time_distance[!is.finite(ev$max_time_distance)] <- NA_real_

ev$log_peak_q_obs <- ifelse(
  is.finite(ev$peak_q_obs) & ev$peak_q_obs > 0,
  log(ev$peak_q_obs),
  NA_real_
)
ev <- add_basin_envelope(ev, "log_peak_q_obs")

ev$peak_q_obs_q10 <- exp(ev$log_peak_q_obs_q10)
ev$peak_q_obs_q90 <- exp(ev$log_peak_q_obs_q90)
ev$peak_amplitude_distance <- ev$log_peak_q_obs_q10q90_distance
ev$peak_over_basin_q90 <- ev$peak_q_obs / ev$peak_q_obs_q90


# ==============================================================================
# Hourly Qobs diagnostics
# ==============================================================================

process_basin <- function(ID) {
  ii <- which(ev$ID == ID)

  fileNC <- file.path(
    dirMain, "data", "forcings", "hourly", ID, paste0(ID, "_input.nc")
  )
  if (!file.exists(fileNC)) {
    stop("Missing forcing file: ", fileNC)
  }

  nc <- nc_open(fileNC)
  q <- as.numeric(ncvar_get(nc, "q_obs"))
  time <- nc_time_to_posixct(
    nc$dim$time$vals,
    nc$dim$time$units,
    experiment
  )
  nc_close(nc)

  stopifnot(length(q) == length(time))
  time_num <- as.numeric(time)

  out <- data.frame(
    row_id_qc = ev$row_id_qc[ii],
    q_start_obs = NA_real_,
    q_end_obs = NA_real_,
    q_start_over_q99 = NA_real_,
    q_end_over_q99 = NA_real_,
    flag_internal_missing = FALSE,
    flag_near_data_gap = FALSE,
    zero_hours_inside_event = NA_integer_,
    flag_zero_inside_event = FALSE,
    peak_neighbor_ratio = NA_real_,
    peak_local_median_ratio = NA_real_,
    peak_width_50_h = NA_integer_,
    noise_ratio = NA_real_,
    reversal_fraction = NA_real_,
    sigrev_e010_n = NA_integer_,
    sigrev_e010_density = NA_real_,
    sigrev_e010_active_fraction = NA_real_,
    sigrev_e010_median_gap_h = NA_real_,
    sigrev_e010_pair_frac_le3h = NA_real_,
    sigrev_e010_max_cluster_3h = NA_integer_,
    tv_excess_range = NA_real_,
    linear_window_start = NA_character_,
    linear_window_end = NA_character_,
    linear_overlap_h = NA_real_,
    linear_r2 = NA_real_,
    linear_rel_rmse = NA_real_,
    linear_dq_cv = NA_real_,
    linear_n_unique_dq = NA_real_,
    flag_linear_qobs = FALSE,
    stringsAsFactors = FALSE
  )

  for (jj in seq_along(ii)) {
    i <- ii[jj]

    k1 <- match(as.numeric(ev$start_posix[i]), time_num)
    kp <- match(as.numeric(ev$peak_posix[i]), time_num)
    k2 <- match(as.numeric(ev$end_posix[i]), time_num)

    if (is.na(k1) || is.na(kp) || is.na(k2) || k1 > kp || kp > k2) {
      stop("Event times not found or invalid for ", ev$event_id[i])
    }

    idx <- k1:k2
    qev <- q[idx]

    out$flag_internal_missing[jj] <- any(!is.finite(qev))
    out$zero_hours_inside_event[jj] <- sum(qev == 0, na.rm = TRUE)
    out$flag_zero_inside_event[jj] <- out$zero_hours_inside_event[jj] > 0L

    context_idx <- seq.int(
      max(1L, k1 - DATA_GAP_CONTEXT_H),
      min(length(q), k2 + DATA_GAP_CONTEXT_H)
    )
    outside_idx <- setdiff(context_idx, idx)
    out$flag_near_data_gap[jj] <- (
      length(outside_idx) > 0L &&
        any(!is.finite(q[outside_idx]))
    )

    if (all(is.finite(qev))) {
      out$q_start_obs[jj] <- qev[1L]
      out$q_end_obs[jj] <- qev[length(qev)]
      out$q_start_over_q99[jj] <- safe_ratio(out$q_start_obs[jj], ev$q99[i])
      out$q_end_over_q99[jj] <- safe_ratio(out$q_end_obs[jj], ev$q99[i])

      k_local <- kp - k1 + 1L

      neighbours <- c(k_local - 1L, k_local + 1L)
      neighbours <- neighbours[
        neighbours >= 1L & neighbours <= length(qev)
      ]
      if (length(neighbours)) {
        neighbour_max <- max(qev[neighbours], na.rm = TRUE)
        out$peak_neighbor_ratio[jj] <- safe_ratio(qev[k_local], neighbour_max)
      }

      local_idx <- seq.int(
        max(1L, k_local - 3L),
        min(length(qev), k_local + 3L)
      )
      local_idx <- setdiff(local_idx, k_local)
      if (length(local_idx)) {
        local_median <- median(qev[local_idx], na.rm = TRUE)
        out$peak_local_median_ratio[jj] <- safe_ratio(
          qev[k_local], local_median
        )
      }

      out$peak_width_50_h[jj] <- peak_width_50(qev, k_local)

      # Descriptive diagnostics retained for QC interpretation.
      out$noise_ratio[jj] <- noise_ratio(qev)
      out$reversal_fraction[jj] <- reversal_fraction(qev)

      sig <- significant_reversal_metrics(
        qev, SIGNIFICANT_SLOPE_FRACTION
      )
      out$sigrev_e010_n[jj] <- as.integer(sig["n"])
      out$sigrev_e010_density[jj] <- sig["density"]
      out$sigrev_e010_active_fraction[jj] <- sig["active_fraction"]
      out$sigrev_e010_median_gap_h[jj] <- sig["median_gap_h"]
      out$sigrev_e010_pair_frac_le3h[jj] <- sig["pair_frac_le3h"]
      out$sigrev_e010_max_cluster_3h[jj] <- as.integer(
        sig["max_cluster_3h"]
      )
      out$tv_excess_range[jj] <- tv_excess_range(qev)
    }

    lin <- scan_linear_qobs(q, time, k1, k2)
    out$linear_window_start[jj] <- lin$start
    out$linear_window_end[jj] <- lin$end
    out$linear_overlap_h[jj] <- lin$overlap_h
    out$linear_r2[jj] <- lin$r2
    out$linear_rel_rmse[jj] <- lin$rel_rmse
    out$linear_dq_cv[jj] <- lin$dq_cv
    out$linear_n_unique_dq[jj] <- lin$n_unique_dq
    out$flag_linear_qobs[jj] <- lin$flag
  }

  out
}


basins <- unique(ev$ID)

cat("\n===== HOURLY QOBS DIAGNOSTICS =====\n\n")
cat("Events  :", nrow(ev), "\n")
cat("Basins  :", length(basins), "\n")
cat("Workers :", NCORES, "\n\n")

results <- parallel::mclapply(
  basins,
  function(ID) {
    cat("Basin ", ID, "\n", sep = "")

    tryCatch(
      process_basin(ID),
      error = function(e) {
        structure(
          list(ID = ID, message = conditionMessage(e)),
          class = "qc_worker_error"
        )
      }
    )
  },
  mc.cores = NCORES,
  mc.preschedule = TRUE
)

is_error <- vapply(
  results, inherits, logical(1), what = "qc_worker_error"
)

if (any(is_error)) {
  cat("\n===== WORKER ERRORS =====\n\n")
  for (z in results[is_error]) {
    cat(z$ID, ": ", z$message, "\n", sep = "")
  }
  stop("At least one basin worker failed.")
}

diag <- do.call(rbind, results)
diag <- diag[order(diag$row_id_qc), , drop = FALSE]

stopifnot(identical(diag$row_id_qc, ev$row_id_qc))

for (nm in setdiff(names(diag), "row_id_qc")) {
  ev[[nm]] <- diag[[nm]]
}


# ==============================================================================
# QC flags and review selection
# ==============================================================================

ev$flag_timing_far <- (
  is.finite(ev$max_time_distance) &
    ev$max_time_distance >= TIME_FAR
)

ev$flag_timing_very_far <- (
  is.finite(ev$max_time_distance) &
    ev$max_time_distance >= TIME_VERY_FAR
)

ev$flag_spike_shape <- (
  is.finite(ev$peak_neighbor_ratio) &
    ev$peak_neighbor_ratio >= SPIKE_NEIGHBOUR_RATIO &
    is.finite(ev$peak_local_median_ratio) &
    ev$peak_local_median_ratio >= SPIKE_LOCAL_RATIO &
    is.finite(ev$peak_width_50_h) &
    ev$peak_width_50_h <= SPIKE_MAX_WIDTH_H
)

ev$flag_peak_amplitude_extreme <- (
  is.finite(ev$peak_amplitude_distance) &
    ev$peak_amplitude_distance >= PEAK_AMPLITUDE_VERY_FAR
)

ev$flag_spike_amplitude_extreme <- (
  ev$flag_spike_shape &
    ev$flag_peak_amplitude_extreme
)

ev$flag_peak_near_end <- (
  is.finite(ev$peak_fraction) &
    ev$peak_fraction >= (1 - PEAK_EDGE_FRACTION) &
    is.finite(ev$recession_h_q10q90_distance) &
    ev$recession_h_q10q90_distance >= TIME_FAR
)

ev$flag_peak_near_start <- (
  is.finite(ev$peak_fraction) &
    ev$peak_fraction <= PEAK_EDGE_FRACTION &
    is.finite(ev$rise_h_q10q90_distance) &
    ev$rise_h_q10q90_distance >= TIME_FAR
)

ev$flag_start_boundary <- (
  is.finite(ev$q_start_over_q99) &
    ev$q_start_over_q99 > 1
)

ev$flag_end_boundary <- (
  is.finite(ev$q_end_over_q99) &
    ev$q_end_over_q99 > 1
)

ev$flag_noisy <- (
  is.finite(ev$sigrev_e010_n) &
    ev$sigrev_e010_n >= NOISE_MIN_SIGNIFICANT_REVERSALS &
    is.finite(ev$sigrev_e010_median_gap_h) &
    ev$sigrev_e010_median_gap_h <= NOISE_MAX_MEDIAN_GAP_H
)

# Timing/shape diagnostics are weak evidence individually and trigger review only
# when at least two are present.
ev$n_morphology_flags <- rowSums(
  cbind(
    ev$flag_timing_far,
    ev$flag_spike_shape,
    ev$flag_peak_near_start,
    ev$flag_peak_near_end
  ),
  na.rm = TRUE
)

ev$review_required <- (
  ev$flag_internal_missing |
    ev$flag_near_data_gap |
    ev$flag_zero_inside_event |
    ev$flag_linear_qobs |
    ev$flag_noisy |
    ev$flag_start_boundary |
    ev$flag_end_boundary |
    ev$flag_timing_very_far |
    ev$flag_peak_amplitude_extreme |
    ev$n_morphology_flags >= 2L
)


# ==============================================================================
# Review reasons
# ==============================================================================

reason <- character(nrow(ev))

for (i in seq_len(nrow(ev))) {
  z <- character(0)

  if (ev$flag_internal_missing[i]) {
    z <- c(z, "internal_missing")
  }
  if (ev$flag_near_data_gap[i]) {
    z <- c(z, "near_data_gap")
  }
  if (ev$flag_zero_inside_event[i]) {
    z <- c(z, "zero_inside")
  }
  if (ev$flag_linear_qobs[i]) {
    z <- c(z, "linear_qobs")
  }
  if (ev$flag_spike_shape[i]) {
    z <- c(z, "spike_shape")
  }
  if (ev$flag_peak_amplitude_extreme[i]) {
    z <- c(z, "peak_amplitude_extreme")
  }
  if (ev$flag_spike_amplitude_extreme[i]) {
    z <- c(z, "spike_amplitude_extreme")
  }
  if (ev$flag_noisy[i]) {
    z <- c(z, "noisy")
  }
  if (ev$flag_timing_very_far[i]) {
    z <- c(z, "timing_very_far")
  }
  if (ev$flag_peak_near_start[i]) {
    z <- c(z, "peak_near_start")
  }
  if (ev$flag_peak_near_end[i]) {
    z <- c(z, "peak_near_end")
  }
  if (ev$flag_start_boundary[i]) {
    z <- c(z, "start_boundary")
  }
  if (ev$flag_end_boundary[i]) {
    z <- c(z, "end_boundary")
  }

  reason[i] <- paste(z, collapse = ";")
}

ev$review_reasons <- reason


# ==============================================================================
# Console summary
# ==============================================================================

flags <- c(
  internal_missing = sum(ev$flag_internal_missing),
  near_data_gap = sum(ev$flag_near_data_gap),
  zero_inside = sum(ev$flag_zero_inside_event),
  linear_qobs = sum(ev$flag_linear_qobs),
  spike_shape = sum(ev$flag_spike_shape),
  peak_amplitude_extreme = sum(ev$flag_peak_amplitude_extreme),
  spike_amplitude_extreme = sum(ev$flag_spike_amplitude_extreme),
  noisy = sum(ev$flag_noisy),
  timing_far = sum(ev$flag_timing_far),
  timing_very_far = sum(ev$flag_timing_very_far),
  peak_near_start = sum(ev$flag_peak_near_start),
  peak_near_end = sum(ev$flag_peak_near_end),
  start_boundary = sum(ev$flag_start_boundary),
  end_boundary = sum(ev$flag_end_boundary),
  review_required = sum(ev$review_required)
)

cat("\n===== OBSERVED FLOOD QC =====\n\n")
cat("Catalogue events              :", nrow(ev), "\n")
print(flags)
cat(
  "\nBasins with review events      :",
  length(unique(ev$ID[ev$review_required])),
  "\n"
)

cat("\n===== NOISE DEFINITION =====\n\n")
cat("Significant slope fraction    :", SIGNIFICANT_SLOPE_FRACTION, "\n")
cat("Minimum significant reversals :", NOISE_MIN_SIGNIFICANT_REVERSALS, "\n")
cat("Maximum median gap [h]        :", NOISE_MAX_MEDIAN_GAP_H, "\n")
cat("Flagged noisy events          :", sum(ev$flag_noisy), "\n")

probs <- c(0, 0.50, 0.75, 0.90, 0.95, 0.99, 0.995, 1)

cat("\n===== SIGNIFICANT REVERSAL COUNT =====\n\n")
print(quantile(
  ev$sigrev_e010_n[is.finite(ev$sigrev_e010_n)],
  probs,
  na.rm = TRUE
))

cat("\n===== SIGNIFICANT REVERSAL MEDIAN GAP [h] =====\n\n")
print(quantile(
  ev$sigrev_e010_median_gap_h[
    is.finite(ev$sigrev_e010_median_gap_h)
  ],
  probs,
  na.rm = TRUE
))

cat("\n===== MAX TIME DISTANCE =====\n\n")
print(quantile(
  ev$max_time_distance,
  c(0, 0.50, 0.90, 0.95, 0.99, 0.995, 1),
  na.rm = TRUE
))

cat("\n===== PEAK AMPLITUDE DISTANCE =====\n\n")
print(quantile(
  ev$peak_amplitude_distance,
  c(0, 0.50, 0.90, 0.95, 0.99, 0.995, 1),
  na.rm = TRUE
))

cat("\n===== PEAK / BASIN Q90 PEAK =====\n\n")
print(quantile(
  ev$peak_over_basin_q90[is.finite(ev$peak_over_basin_q90)],
  c(0, 0.50, 0.90, 0.95, 0.99, 0.995, 1),
  na.rm = TRUE
))

cat("\n===== REVIEW REASONS =====\n\n")
reason_split <- unlist(strsplit(
  ev$review_reasons[
    ev$review_required & ev$review_reasons != ""
  ],
  ";",
  fixed = TRUE
))
print(sort(table(reason_split), decreasing = TRUE))


# ==============================================================================
# Outputs
# ==============================================================================

ev$start_posix <- NULL
ev$peak_posix <- NULL
ev$end_posix <- NULL
ev$row_id_qc <- NULL

write.csv(ev, fileOut, row.names = FALSE)

review <- ev[ev$review_required, , drop = FALSE]
review <- review[
  order(
    -review$flag_linear_qobs,
    -review$flag_spike_amplitude_extreme,
    -review$flag_peak_amplitude_extreme,
    -review$flag_start_boundary,
    -review$flag_end_boundary,
    -review$flag_near_data_gap,
    -review$flag_zero_inside_event,
    -review$flag_noisy,
    -review$max_time_distance,
    na.last = TRUE
  ),
  ,
  drop = FALSE
]

write.csv(review, fileReview, row.names = FALSE)

cat("\nAll diagnostics :", fileOut, "\n")
cat("Review queue    :", fileReview, "\n")
cat("\nOBSERVED FLOOD QC: OK\n")
