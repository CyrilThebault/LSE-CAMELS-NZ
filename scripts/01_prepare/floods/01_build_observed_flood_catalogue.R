# ==============================================================================
# Build the observed flood-event catalogue
#
# Flood events are always detected from hourly observed discharge, independently
# of the temporal resolution used by the LSE experiments.
#
# Method:
#   Qobs -> smoothing -> baseflow -> quickflow -> eventMaxima
#        -> aligned Q99 selection -> BFI95 event boundaries
#        -> BFI95-fragment consolidation
#        -> adjacent high-flow event merge
#        -> sustained Q99 recession boundary
#        -> non-overlapping hourly event windows
#        -> observed flood catalogue
#
# The resulting catalogue is canonical and is subsequently used to evaluate
# both hourly and daily experiments on the same observed floods.
#
# Usage:
#   Rscript scripts/01_prepare/floods/01_build_observed_flood_catalogue.R \
#     /path/to/LSE-CAMELS-NZ [ncores]
# ==============================================================================

library(hydroEvents)


# ==============================================================================
# 1. Configuration
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

force <- length(args) > 0L && tail(args, 1L) == "--force"
if (force) {
  args <- head(args, -1L)
}

if (length(args) < 2L || length(args) > 3L) {
  stop(
    "Usage: Rscript 01_build_observed_flood_catalogue.R <config_file> <dirMain> [ncores] [--force]"
  )
}

config_file <- normalizePath(args[1], mustWork = TRUE)
dirMain <- normalizePath(args[2], mustWork = TRUE)

ncores <- if (length(args) == 3L) {
  suppressWarnings(as.integer(args[3]))
} else {
  1L
}

if (length(ncores) != 1L || is.na(ncores) || ncores < 1L) {
  stop("ncores must be a positive integer")
}

dirOut  <- file.path(dirMain, "data", "flood")
dirDiag <- file.path(dirOut, "diagnostics")

# Protect all persistent catalogue outputs before starting detection.
output_files <- c(
  file.path(dirOut, "observed_flood_catalogue.csv"),
  file.path(dirDiag, "observed_flood_candidates.csv"),
  file.path(dirDiag, "observed_flood_excluded.csv"),
  file.path(dirDiag, "observed_flood_summary.csv")
)

existing <- output_files[file.exists(output_files)]

if (length(existing) && !force) {
  stop(
    "Existing flood catalogue output(s):\n",
    paste(existing, collapse = "\n"),
    "\nUse --force to explicitly allow recalculation."
  )
}

dir.create(dirOut, recursive = TRUE, showWarnings = FALSE)
dir.create(dirDiag, recursive = TRUE, showWarnings = FALSE)

source(file.path(dirMain, "scripts/functions/basins.R"))
source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/floods.R"))

experiment <- load_workflow_config(config_file)

flood_metadata <- read.csv(
  file.path(
    experiment$paths$camels_nz,
    "CAMELS_NZ_Catchment_Atrributes",
    "1.CAMELS_NZ_Catchment_information.csv"
  ),
  fileEncoding = "UTF-8-BOM",
  stringsAsFactors = FALSE,
  check.names = FALSE
)

stopifnot(
  is.character(experiment$timezone),
  length(experiment$timezone) == 1L,
  !is.na(experiment$timezone),
  nzchar(experiment$timezone)
)

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

alpha <- 0.925
delta_y <- -0.75
delta_x <- 12

BFI_Th <- 0.95
Qprob <- 0.99

merge_ratio <- 0.90
merge_gap_h <- 12
recovery_h <- 12L

method <- "hourly_Q99_BFI095_v4"


cat("\n===== OBSERVED HOURLY FLOOD CATALOGUE =====\n\n")
cat("dirMain :", dirMain, "\n")
cat("dirOut  :", dirOut, "\n")
cat("dirDiag :", dirDiag, "\n")
cat("Basins  :", length(basins), "\n")
cat("Cores   :", ncores, "\n")
cat("Method  :", method, "\n\n")


# ==============================================================================
# 2. Helpers
# ==============================================================================



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

  dat <- read_camels_nz_hourly_qobs(ID, experiment, flood_metadata)

  list(
    q = dat$q,
    time = dat$time,
    q99 = unname(
      quantile(dat$q, Qprob, na.rm = TRUE, type = 7)
    )
  )
}


fmt_time <- function(x) {
  format(x, "%Y-%m-%d %H:%M:%S", tz = experiment$timezone)
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


make_groups <- function(n, merge_edge) {
  if (!n) {
    return(integer(0))
  }

  group <- integer(n)
  group[1] <- 1L

  if (n >= 2L) {
    for (i in 2:n) {
      group[i] <- group[i - 1L] + as.integer(!merge_edge[i - 1L])
    }
  }

  group
}


raw_peak <- function(start, end, time, q) {
  idx <- which(time >= start & time <= end)

  stopifnot(
    length(idx) > 0L,
    all(is.finite(q[idx]))
  )

  max(q[idx])
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
  fragments <- list()

  blocks <- get_blocks(is.finite(q))


  # --------------------------------------------------------------------------
  # Detect Q99 candidates and their BFI95 fragments
  # --------------------------------------------------------------------------

  for (bb in seq_len(nrow(blocks))) {
    block_id <- blocks$block_id[bb]
    i1 <- blocks$i1[bb]
    i2 <- blocks$i2[bb]

    qb <- q[i1:i2]
    tb <- time[i1:i2]

    n <- length(qb)

    if (n < 10L) {
      next
    }

    qs <- as.numeric(
      stats::filter(
        qb,
        c(0.1, 0.2, 0.4, 0.2, 0.1)
      )[3:(n - 2L)]
    )

    ts <- tb[3:(n - 2L)]

    if (any(!is.finite(qs))) {
      next
    }

    bf <- baseflowA(qs, alpha = alpha)

    # baseflowA() may return non-finite BFI when both Q and baseflow are zero.
    # Zero flow is treated as a baseflow/no-event state for segmentation.
    bfi_event <- bf$bfi
    zero_bfi <- !is.finite(bfi_event) & qs == 0
    bfi_event[zero_bfi] <- 1

    qf <- qs - bf$bf

    # eventMaxima() requires at least two local minima.
    if (length(hydroEvents::localMin(qf)) < 2L) {
      next
    }

    em <- eventMaxima(
      qf,
      delta.y = delta_y,
      delta.x = delta_x,
      threshold = 0
    )

    if (is.null(em) || !nrow(em)) {
      next
    }

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

    for (j in seq_len(nrow(em))) {
      srt <- as.integer(em$srt[j])
      end <- as.integer(em$end[j])
      peak <- as.integer(em$which.max[j])

      if (
        srt < 1L ||
        end > length(qs) ||
        peak < 1L ||
        peak > length(qs)
      ) {
        next
      }

      # Events touching the smoothed finite-data block edge are censored.
      if (srt <= 1L || end >= length(qs)) {
        next
      }

      peak_time <- ts[peak]

      # ts[1] corresponds to qb[3].
      q_peak_aligned <- qb[peak + 2L]

      if (
        !is.finite(q_peak_aligned) ||
        q_peak_aligned <= q99
      ) {
        next
      }

      m <- integer(0)

      if (!is.null(eb) && nrow(eb)) {
        m <- which(
          eb$start_time <= peak_time &
            eb$end_time >= peak_time
        )
      }

      if (length(m) == 1L) {
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

        fragments[[length(fragments) + 1L]] <- data.frame(
          ID = ID,
          block_id = block_id,
          bfi_event_id = z$bfi_event_id,
          start = z$start_time,
          end = z$end_time,
          q99 = q99
        )

        next
      }

      baseind <- which(bfi_event > BFI_Th)

      before <- baseind[baseind < peak]
      after <- baseind[baseind > peak]

      has_before <- length(before) > 0L
      has_after <- length(after) > 0L

      bfi_peak <- bfi_event[peak]

      reason <- if (length(m) > 1L) {
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
        block_start_reason = if (i1 > 1L) {
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

  fragments <- if (length(fragments)) {
    do.call(rbind, fragments)
  } else {
    data.frame()
  }

  if (nrow(fragments)) {
    fragments <- fragments[
      !duplicated(fragments$bfi_event_id),
      ,
      drop = FALSE
    ]

    fragments <- fragments[
      order(
        fragments$block_id,
        fragments$start
      ),
      ,
      drop = FALSE
    ]

    rownames(fragments) <- NULL
  }


  # --------------------------------------------------------------------------
  # Consolidate retained BFI95 fragments
  #
  # Adjacent fragments are combined when Qobs remains above Q99 throughout
  # the bridge and the bridge minimum remains at least merge_ratio of the
  # smaller adjacent fragment peak.
  # --------------------------------------------------------------------------

  initial_events <- data.frame()

  if (nrow(fragments)) {
    fragment_peak <- vapply(
      seq_len(nrow(fragments)),
      function(i) {
        raw_peak(
          fragments$start[i],
          fragments$end[i],
          time,
          q
        )
      },
      numeric(1)
    )

    fragment_merge <- rep(
      FALSE,
      max(0L, nrow(fragments) - 1L)
    )

    if (nrow(fragments) >= 2L) {
      for (i in seq_len(nrow(fragments) - 1L)) {
        a <- fragments[i, , drop = FALSE]
        b <- fragments[i + 1L, , drop = FALSE]

        if (a$block_id != b$block_id) {
          next
        }

        stopifnot(
          a$end <= b$start,
          isTRUE(
            all.equal(
              a$q99,
              b$q99,
              tolerance = 1e-12
            )
          )
        )

        idx <- which(
          time >= a$end &
            time <= b$start
        )

        stopifnot(
          length(idx) > 0L,
          all(is.finite(q[idx]))
        )

        valley_q <- min(q[idx])
        smaller_peak <- min(
          fragment_peak[i],
          fragment_peak[i + 1L]
        )

        fragment_merge[i] <- (
          valley_q > a$q99 &&
            valley_q / smaller_peak >= merge_ratio
        )
      }
    }

    fragments$fragment_group <- make_groups(
      nrow(fragments),
      fragment_merge
    )

    candidates$fragment_group <- fragments$fragment_group[
      match(
        candidates$bfi_event_id,
        fragments$bfi_event_id
      )
    ]

    stopifnot(
      all(is.finite(candidates$fragment_group))
    )

    initial_events <- lapply(
      split(
        seq_len(nrow(fragments)),
        fragments$fragment_group
      ),
      function(ii) {
        z <- fragments[ii, , drop = FALSE]

        data.frame(
          ID = ID,
          block_id = z$block_id[1],
          fragment_group = z$fragment_group[1],
          start = min(z$start),
          end = max(z$end),
          q99 = z$q99[1],
          n_bfi_fragments = nrow(z),
          stringsAsFactors = FALSE
        )
      }
    )

    initial_events <- do.call(
      rbind,
      initial_events
    )

    rownames(initial_events) <- NULL
  }


  # --------------------------------------------------------------------------
  # Merge adjacent high-flow events
  #
  # Adjacent events are merged when either:
  #
  # 1. high-flow continuity:
  #    Qobs remains above Q99 throughout the inter-event interval;
  #
  # 2. short-gap continuity:
  #    the gap is <= merge_gap_h and the inter-event minimum remains at least
  #    merge_ratio of the smaller adjacent event peak.
  #
  # Merges are never allowed across finite-data blocks.
  # --------------------------------------------------------------------------

  events <- data.frame()

  if (nrow(initial_events)) {
    initial_events <- initial_events[
      order(
        initial_events$block_id,
        initial_events$start
      ),
      ,
      drop = FALSE
    ]

    rownames(initial_events) <- NULL

    event_peak <- vapply(
      seq_len(nrow(initial_events)),
      function(i) {
        raw_peak(
          initial_events$start[i],
          initial_events$end[i],
          time,
          q
        )
      },
      numeric(1)
    )

    event_merge <- rep(
      FALSE,
      max(0L, nrow(initial_events) - 1L)
    )

    if (nrow(initial_events) >= 2L) {
      for (i in seq_len(nrow(initial_events) - 1L)) {
        a <- initial_events[i, , drop = FALSE]
        b <- initial_events[i + 1L, , drop = FALSE]

        if (a$block_id != b$block_id) {
          next
        }

        stopifnot(
          a$end <= b$start,
          isTRUE(
            all.equal(
              a$q99,
              b$q99,
              tolerance = 1e-12
            )
          )
        )

        idx <- which(
          time >= a$end &
            time <= b$start
        )

        stopifnot(
          length(idx) > 0L,
          all(is.finite(q[idx]))
        )

        valley_q <- min(q[idx])

        smaller_peak <- min(
          event_peak[i],
          event_peak[i + 1L]
        )

        gap_h <- as.numeric(
          difftime(
            b$start,
            a$end,
            units = "hours"
          )
        )

        high_flow_continuity <- (
          valley_q > a$q99
        )

        short_gap_continuity <- (
          gap_h <= merge_gap_h &&
            valley_q / smaller_peak >= merge_ratio
        )

        event_merge[i] <- (
          high_flow_continuity ||
            short_gap_continuity
        )
      }
    }

    initial_events$event_group <- make_groups(
      nrow(initial_events),
      event_merge
    )

    candidates$event_group <- initial_events$event_group[
      match(
        candidates$fragment_group,
        initial_events$fragment_group
      )
    ]

    stopifnot(
      all(is.finite(candidates$event_group))
    )

    events <- lapply(
      split(
        seq_len(nrow(initial_events)),
        initial_events$event_group
      ),
      function(ii) {
        z <- initial_events[ii, , drop = FALSE]

        data.frame(
          ID = ID,
          block_id = z$block_id[1],
          event_group = z$event_group[1],
          start = min(z$start),
          end = max(z$end),
          q99 = z$q99[1],
          n_bfi_fragments = sum(z$n_bfi_fragments),
          stringsAsFactors = FALSE
        )
      }
    )

    events <- do.call(
      rbind,
      events
    )

    events <- events[
      order(
        events$block_id,
        events$start
      ),
      ,
      drop = FALSE
    ]

    rownames(events) <- NULL
  }


  # --------------------------------------------------------------------------
  # Extend event ends to sustained Q99 recovery
  #
  # Event starts are unchanged.
  #
  # An event end may move outward to the first hour of the first period with
  # at least recovery_h consecutive observations at or below Q99 after the
  # final retained Q99 candidate.
  #
  # If another independent event follows in the same finite-data block, the
  # extension is clipped at the minimum Qobs between the two event windows.
  # --------------------------------------------------------------------------

  if (nrow(events)) {
    events$end_initial <- events$end
    events$end_extension_h <- 0
    events$end_boundary_source <- "bfi95"

    for (block_id in unique(events$block_id)) {
      ii <- which(events$block_id == block_id)

      ii <- ii[
        order(events$start[ii])
      ]

      block <- blocks[
        blocks$block_id == block_id,
        ,
        drop = FALSE
      ]

      stopifnot(nrow(block) == 1L)

      block_idx <- block$i1:block$i2
      q_block <- q[block_idx]

      stopifnot(
        all(is.finite(q_block))
      )

      low <- q_block <= q99
      r <- rle(low)

      run_end <- cumsum(r$lengths)
      run_start <- run_end - r$lengths + 1L

      keep <- which(
        r$values &
          r$lengths >= recovery_h
      )

      recovery_start <- if (length(keep)) {
        block$i1 + run_start[keep] - 1L
      } else {
        integer(0)
      }

      for (jj in seq_along(ii)) {
        i <- ii[jj]

        end_initial_idx <- match(
          as.numeric(events$end_initial[i]),
          as.numeric(time)
        )

        stopifnot(
          !is.na(end_initial_idx)
        )

        cand <- candidates[
          candidates$event_group == events$event_group[i],
          ,
          drop = FALSE
        ]

        stopifnot(
          nrow(cand) >= 1L
        )

        last_candidate_idx <- match(
          as.numeric(max(cand$candidate_time)),
          as.numeric(time)
        )

        stopifnot(
          !is.na(last_candidate_idx)
        )

        after <- recovery_start[
          recovery_start > last_candidate_idx
        ]

        proposed_end_idx <- if (length(after)) {
          min(after)
        } else {
          end_initial_idx
        }

        # The recovery adjustment never shortens the initial event window.
        final_end_idx <- max(
          end_initial_idx,
          proposed_end_idx
        )

        clipped <- FALSE

        if (jj < length(ii)) {
          next_i <- ii[jj + 1L]

          next_start_idx <- match(
            as.numeric(events$start[next_i]),
            as.numeric(time)
          )

          stopifnot(
            !is.na(next_start_idx),
            end_initial_idx <= next_start_idx
          )

          separator_idx <- end_initial_idx:next_start_idx
          separator_idx <- separator_idx[
            which.min(q[separator_idx])
          ]

          if (final_end_idx > separator_idx) {
            final_end_idx <- separator_idx
            clipped <- TRUE
          }
        }

        events$end[i] <- time[final_end_idx]

        events$end_extension_h[i] <- as.numeric(
          difftime(
            events$end[i],
            events$end_initial[i],
            units = "hours"
          )
        )

        if (events$end_extension_h[i] > 0) {
          events$end_boundary_source[i] <- if (clipped) {
            "inter_event_min"
          } else {
            "q99_recovery_12h"
          }
        }
      }
    }

    stopifnot(
      all(events$end >= events$end_initial)
    )

    # Adjacent events may share one hourly boundary. Assign the shared
    # observation to the later event to keep event windows disjoint.
    # end_boundary_source retains the hydrological boundary source before
    # this discrete one-hour adjustment.
    if (nrow(events) >= 2L) {
      for (block_id in unique(events$block_id)) {
        ii <- which(events$block_id == block_id)
        ii <- ii[order(events$start[ii])]

        if (length(ii) < 2L) {
          next
        }

        for (j in seq_len(length(ii) - 1L)) {
          left <- ii[j]
          right <- ii[j + 1L]

          if (events$end[left] == events$start[right]) {
            events$end[left] <- events$end[left] - 3600
          }
        }
      }

      # Recompute the outward recovery extension after boundary adjustment.
      events$end_extension_h <- pmax(
        0,
        as.numeric(
          difftime(
            events$end,
            events$end_initial,
            units = "hours"
          )
        )
      )

      same_block <- (
        events$block_id[-1L] ==
          events$block_id[-nrow(events)]
      )

      gap_h <- as.numeric(
        difftime(
          events$start[-1L],
          events$end[-nrow(events)],
          units = "hours"
        )
      )

      stopifnot(
        all(events$end >= events$start),
        all(!same_block | gap_h >= 1)
      )
    }

  }


  # --------------------------------------------------------------------------
  # Build final observed-event catalogue
  # --------------------------------------------------------------------------

  catalogue <- list()

  if (nrow(events)) {
    catalogue <- vector(
      "list",
      nrow(events)
    )

    for (i in seq_len(nrow(events))) {
      ev <- events[i, , drop = FALSE]

      cand <- candidates[
        candidates$event_group == ev$event_group,
        ,
        drop = FALSE
      ]

      cand <- cand[
        order(cand$candidate_time),
        ,
        drop = FALSE
      ]

      idx <- which(
        time >= ev$start &
          time <= ev$end
      )

      stopifnot(
        length(idx) > 0L,
        all(is.finite(q[idx]))
      )

      k <- idx[which.max(q[idx])]

      peak_q_obs <- q[k]
      peak_time_obs <- time[k]

      duration_h <- as.numeric(
        difftime(
          ev$end,
          ev$start,
          units = "hours"
        )
      )

      # Qobs is in mm/h and dt = 1 h.
      volume_obs_mm <- sum(q[idx])

      n_candidates <- nrow(cand)

      catalogue[[i]] <- data.frame(
        ID = ID,
        event_id = paste0(
          ID, "_",
          format(
            ev$start,
            "%Y%m%dT%H%M",
            tz = experiment$timezone
          )
        ),
        block_id = ev$block_id,
        start_time = ev$start,
        end_time = ev$end,
        duration_h = duration_h,
        peak_time_obs = peak_time_obs,
        peak_q_obs = peak_q_obs,
        volume_obs_mm = volume_obs_mm,
        q99 = ev$q99,
        peak_over_q99 = peak_q_obs / ev$q99,
        n_q99_candidates = n_candidates,
        n_bfi_fragments = ev$n_bfi_fragments,
        first_candidate_time = min(cand$candidate_time),
        last_candidate_time = max(cand$candidate_time),
        end_extension_h = ev$end_extension_h,
        end_boundary_source = ev$end_boundary_source,
        valid_hours_in_event = length(idx),
        missing_hours_in_event = sum(!is.finite(q[idx])),
        is_censored = FALSE,
        quality_flag = if (n_candidates == 1L) {
          "ok"
        } else {
          "multiple_q99_peaks"
        },
        bfi_threshold = BFI_Th,
        baseflow_alpha = alpha,
        eventmax_delta_y = delta_y,
        eventmax_delta_x = delta_x,
        q_threshold_probability = Qprob,
        merge_ratio_threshold = merge_ratio,
        merge_gap_h = merge_gap_h,
        q99_recovery_hours = recovery_h,
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

  # Internal grouping columns are not part of the diagnostic output.
  if (nrow(candidates)) {
    candidates$fragment_group <- NULL
    candidates$event_group <- NULL
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
    observed_flood_events = nrow(catalogue),
    multi_fragment_events = if (nrow(catalogue)) {
      sum(catalogue$n_bfi_fragments > 1L)
    } else {
      0L
    },
    q99_end_extended_events = if (nrow(catalogue)) {
      sum(catalogue$end_extension_h > 0)
    } else {
      0L
    },
    multiple_q99_peak_events = if (nrow(catalogue)) {
      sum(catalogue$n_q99_candidates > 1L)
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
  results <- lapply(
    basins,
    process_basin
  )
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

candidates <- bind_result(
  results,
  "candidates"
)

excluded <- bind_result(
  results,
  "excluded"
)

catalogue <- bind_result(
  results,
  "catalogue"
)

summary_basin <- bind_result(
  results,
  "summary"
)

if (nrow(catalogue)) {
  catalogue <- catalogue[
    order(
      catalogue$ID,
      catalogue$start_time
    ),
    ,
    drop = FALSE
  ]

  rownames(catalogue) <- NULL
}


# ==============================================================================
# 5. Diagnostics
# ==============================================================================

n_candidates <- sum(
  summary_basin$q99_candidates
)

n_matched <- nrow(candidates)
n_excluded <- nrow(excluded)
n_events <- nrow(catalogue)

cat("\n===== FINAL DIAGNOSTICS =====\n\n")

cat("Q99 eventMaxima candidates :", n_candidates, "\n")
cat("Matched to BFI95           :", n_matched, "\n")
cat("Excluded candidates        :", n_excluded, "\n")
cat("Observed flood events       :", n_events, "\n")

cat(
  "Events with >1 BFI95 fragment :",
  sum(catalogue$n_bfi_fragments > 1L),
  "\n"
)

cat(
  "Q99 end-extended events     :",
  sum(catalogue$end_extension_h > 0),
  "\n"
)


cat("\n===== Q99 PEAKS PER EVENT =====\n\n")

print(
  table(
    catalogue$n_q99_candidates
  )
)


cat("\n===== BFI95 FRAGMENTS PER EVENT =====\n\n")

print(
  table(
    catalogue$n_bfi_fragments
  )
)


cat("\n===== END EXTENSION [h] =====\n\n")

print(
  quantile(
    catalogue$end_extension_h,
    c(0, .50, .90, .95, .99, 1)
  )
)


cat("\n===== EVENT DURATION [h] =====\n\n")

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

print(
  summary_basin,
  row.names = FALSE,
  digits = 5
)


if (nrow(excluded)) {
  cat("\n===== EXCLUSION REASONS =====\n\n")

  print(
    table(
      excluded$exclude_reason
    )
  )
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
    "start_time",
    "end_time",
    "peak_time_obs",
    "first_candidate_time",
    "last_candidate_time"
  )
)


candidates_out <- to_csv(
  candidates,
  c(
    "candidate_time",
    "eventmax_start",
    "eventmax_end",
    "bfi_start",
    "bfi_end"
  )
)


excluded_out <- to_csv(
  excluded,
  c(
    "candidate_time",
    "eventmax_start",
    "eventmax_end"
  )
)


write.csv(
  catalogue_out,
  file.path(
    dirOut,
    "observed_flood_catalogue.csv"
  ),
  row.names = FALSE
)


write.csv(
  candidates_out,
  file.path(
    dirDiag,
    "observed_flood_candidates.csv"
  ),
  row.names = FALSE
)


write.csv(
  excluded_out,
  file.path(
    dirDiag,
    "observed_flood_excluded.csv"
  ),
  row.names = FALSE
)


write.csv(
  summary_basin,
  file.path(
    dirDiag,
    "observed_flood_summary.csv"
  ),
  row.names = FALSE
)


cat("\nFiles written to:", dirOut, "\n")
cat("\nOBSERVED FLOOD CATALOGUE BUILD: OK\n")
