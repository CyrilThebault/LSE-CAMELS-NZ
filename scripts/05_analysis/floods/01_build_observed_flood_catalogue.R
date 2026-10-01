# ==============================================================================
# Build the observed flood-event catalogue
#
# Flood events are always detected from hourly observed discharge, independently
# of the temporal resolution used by the LSE experiments.
#
# Method:
#   Qobs -> smoothing -> baseflow -> quickflow -> eventMaxima
#        -> aligned Q99 selection -> BFI95 event boundaries
#        -> deduplication -> observed flood catalogue
#
# The resulting catalogue is canonical and is subsequently used to evaluate
# both hourly and daily experiments on the same observed floods.
#
# Usage:
#   Rscript scripts/05_analysis/floods/01_build_observed_flood_catalogue.R \
#     /path/to/LSE-CAMELS-NZ [ncores]
# ==============================================================================

library(ncdf4)
library(hydroEvents)


# ==============================================================================
# 1. Configuration
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1L || length(args) > 2L) {
  stop(
    "Usage: Rscript 01_build_observed_flood_catalogue.R <dirMain> [ncores]"
  )
}

dirMain <- normalizePath(args[1], mustWork = TRUE)

ncores <- if (length(args) == 2L) {
  suppressWarnings(as.integer(args[2]))
} else {
  1L
}

if (length(ncores) != 1L || is.na(ncores) || ncores < 1L) {
  stop("ncores must be a positive integer")
}

dirOut  <- file.path(dirMain, "data", "flood")
dirDiag <- file.path(dirOut, "diagnostics")

dir.create(dirOut, recursive = TRUE, showWarnings = FALSE)
dir.create(dirDiag, recursive = TRUE, showWarnings = FALSE)

source(file.path(dirMain, "scripts/functions/basins.R"))

basin_file <- file.path(dirMain, "config", "basins.txt")

if (!file.exists(basin_file)) {
  stop("Missing basin file: ", basin_file)
}

basins <- read_basin_ids(basin_file)

if (!length(basins)) {
  stop("No basin IDs found in: ", basin_file)
}

ncores <- min(ncores, length(basins))


# ==============================================================================
# Method parameters
# ==============================================================================

# Recursive baseflow filter used by hydroEvents::baseflowA(). alpha = 0.925
# follows the hydroEvents hourly example and controls the smoothness/persistence
# of the estimated baseflow.
alpha <- 0.925

# hydroEvents::eventMaxima() parameters used to identify candidate quickflow
# peaks. delta_y = -0.75 requires a 75% relative drop between neighbouring
# peaks, while delta_x = 12 corresponds to 12 hourly time steps. These values
# follow the hydroEvents hourly example and are kept fixed rather than calibrated
# to individual CAMELS-NZ catchments.
delta_y <- -0.75
delta_x <- 12

# Baseflow-index threshold used to define the final hydrological event bounds.
# BFI_Th = 0.95 was retained after visual inspection across representative
# CAMELS-NZ catchments: it generally captures the full rise and recession while
# grouping multiple Q99 sub-peaks belonging to the same flood event.
BFI_Th <- 0.95

# Basin-specific discharge threshold used to retain only extreme-flow
# candidates. Q99 was selected after comparing Q95, Q97.5 and Q99 across the
# benchmark catchments; Q99 reduced event fragmentation while retaining clear
# flood events.
Qprob <- 0.99

# Version label written to the catalogue for reproducibility.
method <- "hourly_Q99_BFI095_v2"


cat("\n===== OBSERVED HOURLY FLOOD CATALOGUE =====\n\n")
cat("dirMain :", dirMain, "\n")
cat("dirOut  :", dirOut, "\n")
cat("dirDiag :", dirDiag, "\n")
cat("Basins  :", length(basins), "\n")
cat("Cores   :", ncores, "\n\n")


# ==============================================================================
# 2. Helpers
# ==============================================================================

decode_time <- function(x, units) {
  z <- regmatches(
    units,
    regexec(
      "^\\s*(seconds|minutes|hours|days)\\s+since\\s+(.+?)\\s*$",
      units,
      ignore.case = TRUE
    )
  )[[1]]

  stopifnot(length(z) == 3)

  origin <- sub(
    "\\s+(UTC|GMT)$", "", trimws(z[3]),
    ignore.case = TRUE
  )

  mult <- switch(
    tolower(z[2]),
    seconds = 1,
    minutes = 60,
    hours   = 3600,
    days    = 86400
  )

  as.POSIXct(origin, tz = "UTC") + x * mult
}


get_blocks <- function(ok) {
  r <- rle(ok)

  i2 <- cumsum(r$lengths)
  i1 <- i2 - r$lengths + 1L

  k <- which(r$values)

  data.frame(
    block_id = seq_along(k),
    i1 = i1[k],
    i2 = i2[k]
  )
}


read_basin <- function(ID) {
  f <- file.path(
    dirMain,
    "data", "forcings", "hourly", ID,
    paste0(ID, "_input.nc")
  )

  if (!file.exists(f)) {
    stop("Missing hourly forcing file: ", f)
  }

  nc <- nc_open(f)
  on.exit(nc_close(nc))

  q <- as.numeric(ncvar_get(nc, "q_obs"))

  time <- decode_time(
    nc$dim$time$vals,
    nc$dim$time$units
  )

  list(
    q = q,
    time = time,
    q99 = unname(
      quantile(q, Qprob, na.rm = TRUE, type = 7)
    )
  )
}


fmt_time <- function(x) {
  format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC")
}


bind_result <- function(results, name) {
  x <- lapply(results, `[[`, name)
  keep <- vapply(x, nrow, integer(1)) > 0L

  if (!any(keep)) {
    return(data.frame())
  }

  out <- do.call(rbind, x[keep])
  rownames(out) <- NULL
  out
}


# ==============================================================================
# 3. Process one basin
# ==============================================================================

process_basin <- function(ID) {
  ID <- as.character(ID)
  ib <- match(ID, basins)
  cat(sprintf("[%03d/%03d] basin %s\n", ib, length(basins), ID))

  dat <- read_basin(ID)
  q <- dat$q
  time <- dat$time
  q99 <- dat$q99

  candidates <- list()
  excluded <- list()
  bfi_events <- list()

  blocks <- get_blocks(is.finite(q))

  for (bb in seq_len(nrow(blocks))) {
    block_id <- blocks$block_id[bb]
    i1 <- blocks$i1[bb]
    i2 <- blocks$i2[bb]

    qb <- q[i1:i2]
    tb <- time[i1:i2]

    n <- length(qb)
    if (n < 10) next

    # --------------------------------------------------------------------------
    # Smooth Q, estimate baseflow and derive quickflow
    # --------------------------------------------------------------------------

    qs <- as.numeric(
      stats::filter(qb, c(0.1, 0.2, 0.4, 0.2, 0.1))[3:(n - 2)]
    )

    ts <- tb[3:(n - 2)]

    if (any(!is.finite(qs))) next

    bf <- baseflowA(qs, alpha = alpha)

    # BFI used for event segmentation only.
    # When discharge is zero, baseflowA() can return a non-finite BFI
    # because both baseflow and discharge are zero. Zero flow represents
    # a no-event/baseflow state, so set these values to 1 for segmentation.
    # Keep bf$bfi unchanged for diagnostic output.
    bfi_event <- bf$bfi
    zero_bfi <- !is.finite(bfi_event) & qs == 0
    bfi_event[zero_bfi] <- 1
    qf <- qs - bf$bf

    # eventMaxima() requires at least two local minima to define an event.
    # hydroEvents::calcStats() does not handle the zero-interval case, so blocks
    # with fewer than two minima cannot contain an eventMaxima event and are skipped.
    if (length(hydroEvents::localMin(qf)) < 2L) {
      next
    }
    
    # --------------------------------------------------------------------------
    # Candidate events from quickflow
    # --------------------------------------------------------------------------

    em <- eventMaxima(
      qf,
      delta.y = delta_y,
      delta.x = delta_x,
      threshold = 0
    )

    if (is.null(em) || !nrow(em)) next

    # --------------------------------------------------------------------------
    # BFI95 events
    # --------------------------------------------------------------------------

    eb <- eventBaseflow(
      data = qs,
      BFI_Th = BFI_Th,
      bfi = bfi_event,
      min.length = 1,
      out.style = "none"
    )

    if (!is.null(eb) && nrow(eb)) {
      eb$start_time <- ts[eb$srt]
      eb$end_time <- ts[eb$end]

      eb$bfi_event_id <- paste(
        ID, block_id, eb$srt, eb$end,
        sep = "_"
      )
    }

    # --------------------------------------------------------------------------
    # Q99 selection at the eventMaxima quickflow peak
    # --------------------------------------------------------------------------

    for (j in seq_len(nrow(em))) {
      srt <- as.integer(em$srt[j])
      end <- as.integer(em$end[j])
      peak <- as.integer(em$which.max[j])

      if (
        srt < 1 ||
        end > length(qs) ||
        peak < 1 ||
        peak > length(qs)
      ) next

      # Do not retain eventMaxima events touching a finite-data block edge.
      if (srt <= 1 || end >= length(qs)) next

      peak_time <- ts[peak]

      # ts[1] corresponds to qb[3].
      q_peak_aligned <- qb[peak + 2L]

      if (
        !is.finite(q_peak_aligned) ||
        q_peak_aligned <= q99
      ) next

      # ------------------------------------------------------------------------
      # Match Q99 candidate to BFI95 event
      # ------------------------------------------------------------------------

      m <- integer(0)

      if (!is.null(eb) && nrow(eb)) {
        m <- which(
          eb$start_time <= peak_time &
            eb$end_time >= peak_time
        )
      }

      if (length(m) == 1) {
        z <- eb[m, , drop = FALSE]

        candidates[[length(candidates) + 1L]] <- data.frame(
          ID = ID,
          block_id = block_id,
          candidate_time = peak_time,
          candidate_q_obs = q_peak_aligned,
          candidate_peak_over_q99 = q_peak_aligned / q99,
          eventmax_start = ts[srt],
          eventmax_end = ts[end],
          eventmax_duration_h = as.numeric(
            difftime(ts[end], ts[srt], units = "hours")
          ),
          quickflow_peak = qf[peak],
          bfi_at_candidate = bf$bfi[peak],
          bfi_event_id = z$bfi_event_id,
          bfi_start = z$start_time,
          bfi_end = z$end_time,
          q99 = q99
        )

        bfi_events[[length(bfi_events) + 1L]] <- data.frame(
          ID = ID,
          block_id = block_id,
          bfi_event_id = z$bfi_event_id,
          bfi_start = z$start_time,
          bfi_end = z$end_time,
          q99 = q99
        )

        next
      }

      # ------------------------------------------------------------------------
      # Unmatched candidate: keep diagnostic and exclusion reason
      # ------------------------------------------------------------------------

      baseind <- which(bfi_event > BFI_Th)

      before <- baseind[baseind < peak]
      after <- baseind[baseind > peak]

      has_before <- length(before) > 0
      has_after <- length(after) > 0

      bfi_peak <- bfi_event[peak]

      reason <- if (length(m) > 1) {
        "multiple_bfi95_matches"
      } else if (
        is.finite(bfi_peak) &&
        bfi_peak >= BFI_Th
      ) {
        "bfi_at_peak_ge_0.95"
      } else if (!has_after) {
        "no_bfi95_closure_before_block_end"
      } else if (!has_before) {
        "no_bfi95_opening_after_block_start"
      } else {
        "unmatched_other"
      }

      excluded[[length(excluded) + 1L]] <- data.frame(
        ID = ID,
        block_id = block_id,
        candidate_time = peak_time,
        candidate_q_obs = q_peak_aligned,
        q99 = q99,
        candidate_peak_over_q99 = q_peak_aligned / q99,
        eventmax_start = ts[srt],
        eventmax_end = ts[end],
        eventmax_duration_h = as.numeric(
          difftime(ts[end], ts[srt], units = "hours")
        ),
        bfi_at_candidate = bf$bfi[peak],
        n_bfi_matches = length(m),
        has_bfi95_before = has_before,
        hours_since_bfi95 = if (has_before) peak - max(before) else NA,
        has_bfi95_after = has_after,
        hours_until_bfi95 = if (has_after) min(after) - peak else NA,
        hours_from_block_start = peak - 1L,
        hours_to_block_end = length(qs) - peak,
        block_start_reason = if (i1 > 1) {
          "missing_data_gap"
        } else {
          "dataset_start"
        },
        block_end_reason = if (i2 < length(q)) {
          "missing_data_gap"
        } else {
          "dataset_end"
        },
        exclude_reason = reason
      )
    }
  }

  # --------------------------------------------------------------------------
  # Deduplicate BFI95 events
  # --------------------------------------------------------------------------

  candidates <- if (length(candidates)) {
    do.call(rbind, candidates)
  } else {
    data.frame()
  }

  excluded <- if (length(excluded)) {
    do.call(rbind, excluded)
  } else {
    data.frame()
  }

  bfi_events <- if (length(bfi_events)) {
    do.call(rbind, bfi_events)
  } else {
    data.frame()
  }

  if (nrow(bfi_events)) {
    bfi_events <- bfi_events[
      !duplicated(bfi_events$bfi_event_id),
      ,
      drop = FALSE
    ]
  }

  # --------------------------------------------------------------------------
  # Build final observed-event catalogue
  # --------------------------------------------------------------------------

  catalogue <- list()

  if (nrow(bfi_events)) {
    catalogue <- vector("list", nrow(bfi_events))

    for (i in seq_len(nrow(bfi_events))) {
      ev <- bfi_events[i, , drop = FALSE]

      cand <- candidates[
        candidates$bfi_event_id == ev$bfi_event_id,
        ,
        drop = FALSE
      ]

      cand <- cand[
        order(cand$candidate_time),
        ,
        drop = FALSE
      ]

      idx <- which(
        time >= ev$bfi_start &
          time <= ev$bfi_end
      )

      stopifnot(
        length(idx) > 0,
        all(is.finite(q[idx]))
      )

      k <- idx[which.max(q[idx])]

      peak_q_obs <- q[k]
      peak_time_obs <- time[k]

      duration_h <- as.numeric(
        difftime(ev$bfi_end, ev$bfi_start, units = "hours")
      )

      # Qobs is in mm/h and dt = 1 h.
      volume_obs_mm <- sum(q[idx])

      n_candidates <- nrow(cand)

      catalogue[[i]] <- data.frame(
        ID = ID,
        event_id = paste0(
          ID, "_",
          format(ev$bfi_start, "%Y%m%dT%H%M", tz = "UTC")
        ),
        block_id = ev$block_id,
        start_time = ev$bfi_start,
        end_time = ev$bfi_end,
        duration_h = duration_h,
        peak_time_obs = peak_time_obs,
        peak_q_obs = peak_q_obs,
        volume_obs_mm = volume_obs_mm,
        q99 = ev$q99,
        peak_over_q99 = peak_q_obs / ev$q99,
        n_q99_candidates = n_candidates,
        first_candidate_time = min(cand$candidate_time),
        last_candidate_time = max(cand$candidate_time),
        valid_hours_in_event = length(idx),
        missing_hours_in_event = sum(!is.finite(q[idx])),
        is_censored = FALSE,
        quality_flag = if (n_candidates == 1) {
          "ok"
        } else {
          "multiple_q99_peaks"
        },
        bfi_threshold = BFI_Th,
        baseflow_alpha = alpha,
        eventmax_delta_y = delta_y,
        eventmax_delta_x = delta_x,
        q_threshold_probability = Qprob,
        method_version = method
      )
    }
  }

  catalogue <- if (length(catalogue)) {
    do.call(rbind, catalogue)
  } else {
    data.frame()
  }

  if (nrow(catalogue)) {
    catalogue <- catalogue[
      order(catalogue$start_time),
      ,
      drop = FALSE
    ]
  }

  rownames(candidates) <- NULL
  rownames(excluded) <- NULL
  rownames(catalogue) <- NULL

  summary <- data.frame(
    ID = ID,
    q99 = q99,
    q99_candidates = nrow(candidates) + nrow(excluded),
    matched_candidates = nrow(candidates),
    excluded_candidates = nrow(excluded),
    unique_BFI95_events = nrow(catalogue),
    duplicate_Q99_candidates = nrow(candidates) - nrow(catalogue),
    multi_peak_BFI95_events = if (nrow(catalogue)) {
      sum(catalogue$n_q99_candidates > 1)
    } else {
      0L
    }
  )

  list(
    candidates = candidates,
    excluded = excluded,
    catalogue = catalogue,
    summary = summary
  )
}


# ==============================================================================
# 4. Process basins
# ==============================================================================

if (ncores == 1L) {
  results <- lapply(basins, process_basin)
} else {
  results <- parallel::mclapply(
    basins,
    process_basin,
    mc.cores = ncores,
    mc.preschedule = FALSE
  )
}

failed <- vapply(
  results,
  function(x) inherits(x, "try-error"),
  logical(1)
)

if (any(failed)) {
  stop(
    "Flood catalogue failed for basin(s): ",
    paste(basins[failed], collapse = ", ")
  )
}

candidates <- bind_result(results, "candidates")
excluded <- bind_result(results, "excluded")
catalogue <- bind_result(results, "catalogue")
summary_basin <- bind_result(results, "summary")

if (nrow(catalogue)) {
  catalogue <- catalogue[
    order(catalogue$ID, catalogue$start_time),
    ,
    drop = FALSE
  ]
  rownames(catalogue) <- NULL
}


# ==============================================================================
# 5. Diagnostics
# ==============================================================================

n_candidates <- sum(summary_basin$q99_candidates)
n_matched <- nrow(candidates)
n_excluded <- nrow(excluded)
n_events <- nrow(catalogue)

cat("\n===== FINAL DIAGNOSTICS =====\n\n")

cat("Q99 eventMaxima candidates :", n_candidates, "\n")
cat("Matched to BFI95           :", n_matched, "\n")
cat("Excluded candidates        :", n_excluded, "\n")
cat("Unique BFI95 events        :", n_events, "\n")

cat("\n===== Q99 PEAKS PER BFI95 EVENT =====\n\n")
print(table(catalogue$n_q99_candidates))

cat("\n===== BFI95 EVENT DURATIONS [h] =====\n\n")
print(
  quantile(
    catalogue$duration_h,
    c(0, .25, .50, .75, .90, .95, .99, 1)
  )
)

cat("\n===== PEAK / Q99 =====\n\n")
print(
  quantile(
    catalogue$peak_over_q99,
    c(0, .25, .50, .75, .90, .95, .99, 1)
  )
)

cat("\n===== PER-BASIN SUMMARY =====\n\n")
print(summary_basin, row.names = FALSE, digits = 5)

if (nrow(excluded)) {
  cat("\n===== EXCLUSION REASONS =====\n\n")
  print(table(excluded$exclude_reason))
}


# ==============================================================================
# 6. Write outputs
# ==============================================================================

to_csv <- function(x, time_cols) {
  for (v in intersect(time_cols, names(x))) {
    x[[v]] <- fmt_time(x[[v]])
  }

  x
}

catalogue_out <- to_csv(
  catalogue,
  c(
    "start_time", "end_time", "peak_time_obs",
    "first_candidate_time", "last_candidate_time"
  )
)

candidates_out <- to_csv(
  candidates,
  c(
    "candidate_time",
    "eventmax_start", "eventmax_end",
    "bfi_start", "bfi_end"
  )
)

excluded_out <- to_csv(
  excluded,
  c(
    "candidate_time",
    "eventmax_start", "eventmax_end"
  )
)

write.csv(
  catalogue_out,
  file.path(dirOut, "observed_flood_catalogue.csv"),
  row.names = FALSE
)

write.csv(
  candidates_out,
  file.path(dirDiag, "observed_flood_candidates.csv"),
  row.names = FALSE
)

write.csv(
  excluded_out,
  file.path(dirDiag, "observed_flood_excluded.csv"),
  row.names = FALSE
)

write.csv(
  summary_basin,
  file.path(dirDiag, "observed_flood_summary.csv"),
  row.names = FALSE
)

cat("\nFiles written to:", dirOut, "\n")
cat("\nOBSERVED FLOOD CATALOGUE BUILD: OK\n")
