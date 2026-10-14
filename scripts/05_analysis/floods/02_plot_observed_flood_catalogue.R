#!/usr/bin/env Rscript

library(ncdf4)
library(ggplot2)
library(grid)
library(sf)


# ==============================================================================
# Arguments
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 4L) {
  stop(
    paste(
      "Usage:",
      "Rscript 02_plot_observed_flood_catalogue.R",
      "<dirMain> <events.csv> <ID> <output.pdf>"
    )
  )
}

dirMain <- normalizePath(args[1], mustWork = TRUE)
fileEvents <- normalizePath(args[2], mustWork = TRUE)
ID <- as.character(args[3])
fileOut <- args[4]

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


# ==============================================================================
# Helpers
# ==============================================================================



parse_time <- function(x) {
  as.POSIXct(
    x,
    format = "%Y-%m-%d %H:%M:%S",
    tz = experiment$timezone
  )
}


parse_cols <- function(x, cols) {

  for (v in intersect(cols, names(x))) {
    x[[v]] <- parse_time(x[[v]])
  }

  x
}


matches_id <- function(x, id) {

  x_chr <- trimws(as.character(x))
  id_chr <- trimws(as.character(id))

  out <- x_chr == id_chr

  id_num <- suppressWarnings(
    as.numeric(id_chr)
  )

  x_num <- suppressWarnings(
    as.numeric(x_chr)
  )

  if (!is.na(id_num)) {
    out <- out |
      (
        !is.na(x_num) &
          x_num == id_num
      )
  }

  out
}


find_id_column <- function(x, id) {

  preferred <- c(
    "Station_ID", "station_id", "STATION_ID",
    "StationID", "stationid",
    "Site_ID", "site_id", "SITE_ID",
    "ID", "Id", "id", "RID"
  )

  attributes <- setdiff(
    names(x),
    attr(x, "sf_column")
  )

  for (nm in intersect(
    preferred,
    attributes
  )) {

    if (any(
      matches_id(
        x[[nm]],
        id
      ),
      na.rm = TRUE
    )) {
      return(nm)
    }
  }

  hits <- attributes[
    vapply(
      attributes,
      function(nm) {

        !is.list(x[[nm]]) &&
          any(
            matches_id(
              x[[nm]],
              id
            ),
            na.rm = TRUE
          )
      },
      logical(1)
    )
  ]

  if (length(hits) == 1L) {
    return(hits)
  }

  if (length(hits) > 1L) {
    stop(
      "Basin ID ",
      id,
      " was found in several catchment attributes: ",
      paste(
        hits,
        collapse = ", "
      )
    )
  }

  stop(
    "Could not find basin ID ",
    id,
    " in All_Nested_Catchments.shp."
  )
}


summary_stats <- function(x) {

  x <- x[
    is.finite(x)
  ]

  if (!length(x)) {
    return(
      c(
        min = NA_real_,
        p05 = NA_real_,
        median = NA_real_,
        p95 = NA_real_,
        max = NA_real_
      )
    )
  }

  c(
    min = min(x),
    p05 = unname(
      quantile(
        x,
        0.05
      )
    ),
    median = median(x),
    p95 = unname(
      quantile(
        x,
        0.95
      )
    ),
    max = max(x)
  )
}


fmt <- function(x, digits = 2L) {

  if (
    !length(x) ||
      is.na(x) ||
      !is.finite(x)
  ) {
    return("NA")
  }

  format(
    round(
      x,
      digits
    ),
    trim = TRUE,
    scientific = FALSE
  )
}


fmt_stats <- function(x, digits, unit = "") {

  paste0(
    "Minimum: ", fmt(x["min"], digits), unit,
    "\nP05: ", fmt(x["p05"], digits), unit,
    "\nMedian: ", fmt(x["median"], digits), unit,
    "\nP95: ", fmt(x["p95"], digits), unit,
    "\nMaximum: ", fmt(x["max"], digits), unit
  )
}





text_value <- function(e, name) {

  if (!name %in% names(e)) {
    return("")
  }

  z <- as.character(
    e[[name]][1]
  )

  if (
    is.na(z) ||
      !nzchar(z)
  ) {
    return("")
  }

  z
}


print_grid <- function(
  plots,
  nrow,
  ncol
) {

  grid.newpage()

  pushViewport(
    viewport(
      layout = grid.layout(
        nrow,
        ncol
      )
    )
  )

  for (i in seq_along(plots)) {

    row <- ((i - 1L) %/% ncol) + 1L
    col <- ((i - 1L) %% ncol) + 1L

    print(
      plots[[i]],
      vp = viewport(
        layout.pos.row = row,
        layout.pos.col = col
      ),
      newpage = FALSE
    )
  }

  popViewport()
}


# ==============================================================================
# Input files
# ==============================================================================

fileCatalogue <- file.path(
  dirMain,
  "data",
  "flood",
  "observed_flood_catalogue.csv"
)



fileExcluded <- file.path(
  dirMain,
  "data",
  "flood",
  "diagnostics",
  "observed_flood_excluded.csv"
)

fileNC <- file.path(
  dirMain,
  "data",
  "forcings",
  "hourly",
  ID,
  paste0(
    ID,
    "_input.nc"
  )
)

fileStations <- file.path(
  dirMain,
  "shapefiles",
  "camel_stationsNZ.shp"
)

fileNZ <- file.path(
  dirMain,
  "shapefiles",
  "nz.shp"
)

fileCatchments <- file.path(
  dirMain,
  "shapefiles",
  "All_Nested_Catchments.shp"
)

filesRequired <- c(
  fileEvents,
  fileCatalogue,
  fileExcluded,
  fileNC,
  fileStations,
  fileNZ,
  fileCatchments
)

missingFiles <- filesRequired[
  !file.exists(
    filesRequired
  )
]

if (length(missingFiles)) {
  stop(
    "Missing required file(s):\n",
    paste(
      missingFiles,
      collapse = "\n"
    )
  )
}


# ==============================================================================
# Event tables
# ==============================================================================

events <- read.csv(
  fileEvents,
  stringsAsFactors = FALSE
)

catalogue <- read.csv(
  fileCatalogue,
  stringsAsFactors = FALSE
)



excluded <- read.csv(
  fileExcluded,
  stringsAsFactors = FALSE
)

requiredEventColumns <- c(
  "ID",
  "event_id",
  "start_time",
  "end_time",
  "peak_time_obs",
  "peak_q_obs",
  "q99"
)

missingColumns <- setdiff(
  requiredEventColumns,
  names(events)
)

if (length(missingColumns)) {
  stop(
    "Input event table is missing required columns: ",
    paste(
      missingColumns,
      collapse = ", "
    )
  )
}

events$ID <- as.character(
  events$ID
)

catalogue$ID <- as.character(
  catalogue$ID
)



excluded$ID <- as.character(
  excluded$ID
)

timeColumns <- c(
  "start_time",
  "end_time",
  "peak_time_obs",
  "first_candidate_time",
  "last_candidate_time"
)

events <- parse_cols(
  events,
  timeColumns
)

catalogue <- parse_cols(
  catalogue,
  timeColumns
)



excluded <- parse_cols(
  excluded,
  c(
    "candidate_time",
    "eventmax_start",
    "eventmax_end"
  )
)

ev <- events[
  events$ID == ID,
  ,
  drop = FALSE
]

canonical <- catalogue[
  catalogue$ID == ID,
  ,
  drop = FALSE
]



exc <- excluded[
  excluded$ID == ID,
  ,
  drop = FALSE
]

if (!nrow(canonical)) {
  stop(
    "No canonical catalogue events found for basin ",
    ID
  )
}

if (!nrow(ev)) {
  stop(
    "No events from ",
    basename(fileEvents),
    " found for basin ",
    ID
  )
}

ev <- ev[
  order(
    ev$start_time
  ),
  ,
  drop = FALSE
]

canonical <- canonical[
  order(
    canonical$start_time
  ),
  ,
  drop = FALSE
]

rownames(ev) <- NULL
rownames(canonical) <- NULL


# Derive basic fields when absent from the selected event table.

if (!"duration_h" %in% names(ev)) {

  ev$duration_h <- as.numeric(
    difftime(
      ev$end_time,
      ev$start_time,
      units = "hours"
    )
  )
}

if (!"peak_over_q99" %in% names(ev)) {

  ev$peak_over_q99 <- (
    ev$peak_q_obs /
      ev$q99
  )
}

if (!"volume_obs_mm" %in% names(ev)) {
  ev$volume_obs_mm <- NA_real_
}

ev$year <- as.integer(
  format(
    ev$peak_time_obs,
    "%Y"
  )
)

if ("n_q99_candidates" %in% names(ev)) {

  ev$event_type <- ifelse(
    ev$n_q99_candidates > 1,
    "Multiple Q99 peaks",
    "Single Q99 peak"
  )

} else {

  ev$event_type <- "Selected event"
}


# ==============================================================================
# Hourly observed discharge
# ==============================================================================

nc <- nc_open(
  fileNC
)

q <- as.numeric(
  ncvar_get(
    nc,
    "q_obs"
  )
)

time <- nc_time_to_posixct(
  nc$dim$time$vals,
  nc$dim$time$units,
  experiment
)

nc_close(
  nc
)

hydro <- data.frame(
  time = time,
  q = q
)


# ==============================================================================
# Spatial data
# ==============================================================================

stationsSF <- st_read(
  fileStations,
  quiet = TRUE
)

nzSF <- st_read(
  fileNZ,
  quiet = TRUE
)

catchmentsSF <- st_read(
  fileCatchments,
  quiet = TRUE
)

stationsSF$Station_ID <- as.character(
  stationsSF$Station_ID
)

stationSF <- stationsSF[
  stationsSF$Station_ID == ID,
  ,
  drop = FALSE
]

if (nrow(stationSF) != 1L) {
  stop(
    "Expected exactly one station for basin ",
    ID,
    ", found ",
    nrow(stationSF)
  )
}

catchmentIDColumn <- find_id_column(
  catchmentsSF,
  ID
)

catchmentSF <- catchmentsSF[
  matches_id(
    catchmentsSF[[catchmentIDColumn]],
    ID
  ),
  ,
  drop = FALSE
]

if (nrow(catchmentSF) != 1L) {
  stop(
    "Expected exactly one catchment polygon for basin ",
    ID,
    ", found ",
    nrow(catchmentSF)
  )
}

stationsWGS84 <- st_transform(
  stationsSF,
  4326
)

stationWGS84 <- stationsWGS84[
  stationsWGS84$Station_ID == ID,
  ,
  drop = FALSE
]

catchmentWGS84 <- st_transform(
  catchmentSF,
  4326
)

nzWGS84 <- st_transform(
  nzSF,
  4326
)


# ==============================================================================
# Basin and event-set diagnostics
# ==============================================================================

stationName <- as.character(
  stationSF$Station_Na[1]
)

uparea <- as.numeric(
  stationSF$uparea[1]
)

elevation <- as.numeric(
  stationSF$elevation[1]
)

streamOrder <- as.numeric(
  stationSF$Stream_Ord[1]
)

totalObservedRecords <- as.numeric(
  stationSF$Records[1]
)

recordStart <- min(
  hydro$time,
  na.rm = TRUE
)

recordEnd <- max(
  hydro$time,
  na.rm = TRUE
)

recordYears <- as.numeric(
  difftime(
    recordEnd,
    recordStart,
    units = "days"
  )
) / 365.25

selectedEventsPerYear <- (
  nrow(ev) /
    recordYears
)

durationStats <- summary_stats(
  ev$duration_h
)

peakRatioStats <- summary_stats(
  ev$peak_over_q99
)

volumeStats <- summary_stats(
  ev$volume_obs_mm
)

methodVersion <- if (
  "method_version" %in% names(ev)
) {

  paste(
    unique(
      ev$method_version
    ),
    collapse = ", "
  )

} else {

  paste(
    unique(
      canonical$method_version
    ),
    collapse = ", "
  )
}

nMulti <- if (
  "n_q99_candidates" %in% names(ev)
) {

  sum(
    ev$n_q99_candidates > 1,
    na.rm = TRUE
  )

} else {

  NA_integer_
}

nMultiFragment <- if (
  "n_bfi_fragments" %in% names(ev)
) {

  sum(
    ev$n_bfi_fragments > 1,
    na.rm = TRUE
  )

} else {

  NA_integer_
}

nEndExtended <- if (
  "end_extension_h" %in% names(ev)
) {

  sum(
    ev$end_extension_h > 0,
    na.rm = TRUE
  )

} else {

  NA_integer_
}

reasonText <- if (nrow(exc)) {

  tab <- sort(
    table(
      exc$exclude_reason
    ),
    decreasing = TRUE
  )

  paste(
    paste0(
      names(tab),
      ": ",
      as.integer(tab)
    ),
    collapse = "\n"
  )

} else {

  "None"
}


# ==============================================================================
# Optional QC summary
# ==============================================================================

qcReasonText <- ""

if ("review_reasons" %in% names(ev)) {

  z <- ev$review_reasons

  z <- z[
    !is.na(z) &
      nzchar(z)
  ]

  if (length(z)) {

    reasons <- unlist(
      strsplit(
        z,
        ";",
        fixed = TRUE
      )
    )

    tab <- sort(
      table(
        reasons
      ),
      decreasing = TRUE
    )

    qcReasonText <- paste(
      paste0(
        names(tab),
        ": ",
        as.integer(tab)
      ),
      collapse = "\n"
    )
  }
}

qcStatusText <- ""

if ("qc_status" %in% names(ev)) {

  tab <- sort(
    table(
      ev$qc_status,
      useNA = "ifany"
    ),
    decreasing = TRUE
  )

  qcStatusText <- paste(
    paste0(
      names(tab),
      ": ",
      as.integer(tab)
    ),
    collapse = "\n"
  )
}

hasQC <- any(
  c(
    "quick_review",
    "quick_review_reasons",
    "review_reasons",
    "flag_noisy",
    "flag_linear_qobs",
    "qc_status"
  ) %in% names(ev)
)


# ==============================================================================
# Plot themes
# ==============================================================================

themeSummary <- theme_bw(
  base_size = 10
) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    plot.title = element_text(
      face = "bold",
      size = 11
    ),
    axis.title = element_text(
      size = 9
    ),
    axis.text = element_text(
      size = 8
    ),
    plot.margin = margin(
      5,
      5,
      5,
      5
    )
  )

themeEvent <- theme_bw(
  base_size = if (hasQC) 9 else 7
) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    plot.title = element_text(
      size = if (hasQC) 9 else 7.5,
      face = "bold",
      margin = margin(b = 1)
    ),
    plot.subtitle = element_text(
      size = if (hasQC) 7 else 5.8,
      margin = margin(b = 2)
    ),
    axis.title = element_text(
      size = if (hasQC) 8 else 6.5
    ),
    axis.text = element_text(
      size = if (hasQC) 7 else 5.5
    ),
    plot.margin = margin(
      4,
      4,
      4,
      4
    )
  )

themeMap <- theme_void() +
  theme(
    plot.title = element_text(
      face = "bold",
      size = 11
    ),
    panel.border = element_rect(
      colour = "grey30",
      fill = NA,
      linewidth = 0.7
    ),
    plot.margin = margin(
      5,
      5,
      5,
      5
    )
  )


# ==============================================================================
# Summary page
# ==============================================================================

summarySections <- list(
  list(
    title = "Station",
    content = paste0(
      stationName,
      "\nStation ID: ",
      ID,
      "\nUpstream area: ",
      round(
        uparea,
        1
      ),
      " km2",
      "\nElevation: ",
      round(
        elevation,
        1
      ),
      " m a.s.l.",
      "\nStream order: ",
      streamOrder,
      "\nTotal observed records: ",
      round(
        totalObservedRecords,
        1
      ),
      " years"
    )
  ),
  list(
    title = "Observed record used",
    content = paste0(
      "Start: ",
      format(
        recordStart,
        "%Y-%m-%d"
      ),
      "\nEnd: ",
      format(
        recordEnd,
        "%Y-%m-%d"
      ),
      "\nLength: ",
      round(
        recordYears,
        1
      ),
      " years"
    )
  ),
  list(
    title = "Input event set",
    content = paste0(
      "File: ",
      basename(
        fileEvents
      ),
      "\nSelected events: ",
      nrow(ev),
      "\nCanonical events: ",
      nrow(canonical),
      "\nSelected events/year: ",
      round(
        selectedEventsPerYear,
        2
      ),
      "\nQ99: ",
      format(
        ev$q99[1],
        digits = 5
      ),
      " mm/h",
      "\nMethod: ",
      methodVersion
    )
  ),
  list(
    title = "Segmentation diagnostics",
    content = paste0(
      "Multi-Q99 events: ",
      ifelse(
        is.na(nMulti),
        "NA",
        nMulti
      ),
      "\n>1 BFI95 fragment: ",
      ifelse(
        is.na(nMultiFragment),
        "NA",
        nMultiFragment
      ),
      "\nQ99 end extended: ",
      ifelse(
        is.na(nEndExtended),
        "NA",
        nEndExtended
      )
    )
  ),
  list(
    title = "Event duration",
    content = fmt_stats(
      durationStats,
      1,
      " h"
    )
  ),
  list(
    title = "Peak / Q99",
    content = fmt_stats(
      peakRatioStats,
      2
    )
  ),
  list(
    title = "Event volume",
    content = fmt_stats(
      volumeStats,
      1,
      " mm"
    )
  ),
  list(
    title = "Detection candidates excluded",
    content = paste0(
      "Candidates: ",
      nrow(exc),
      if (nrow(exc)) {
        paste0(
          "\n",
          reasonText
        )
      } else {
        ""
      }
    )
  )
)

if (nzchar(qcReasonText)) {

  summarySections[[length(summarySections) + 1L]] <- list(
    title = "QC review reasons",
    content = qcReasonText
  )
}

if (nzchar(qcStatusText)) {

  summarySections[[length(summarySections) + 1L]] <- list(
    title = "QC status",
    content = qcStatusText
  )
}


make_summary_grob <- function(sections) {

  grobs <- list()

  add <- function(g) {
    grobs[[length(grobs) + 1L]] <<- g
  }

  xLeft <- unit(
    0.02,
    "npc"
  )

  y <- unit(
    0.99,
    "npc"
  )

  lineGap <- unit(
    3.5,
    "mm"
  )

  title <- textGrob(
    "Observed flood events",
    x = xLeft,
    y = y,
    just = c(
      "left",
      "top"
    ),
    gp = gpar(
      fontsize = 16,
      fontface = "bold"
    )
  )

  add(title)

  y <- y -
    grobHeight(title) -
    2.5 * lineGap

  for (section in sections) {

    heading <- textGrob(
      section$title,
      x = xLeft,
      y = y,
      just = c(
        "left",
        "top"
      ),
      gp = gpar(
        fontsize = 10.5,
        fontface = "bold"
      )
    )

    add(heading)

    y <- y -
      grobHeight(heading) -
      lineGap

    content <- textGrob(
      section$content,
      x = xLeft,
      y = y,
      just = c(
        "left",
        "top"
      ),
      gp = gpar(
        fontsize = 9.2,
        lineheight = 1.02
      )
    )

    add(content)

    y <- y -
      grobHeight(content) -
      1.5 * lineGap
  }

  do.call(
    grobTree,
    grobs
  )
}

summaryGrob <- make_summary_grob(
  summarySections
)


# ==============================================================================
# Maps
# ==============================================================================

pMapNZ <- ggplot() +
  geom_sf(
    data = nzWGS84,
    fill = "grey95",
    colour = "grey55",
    linewidth = 0.25
  ) +
  geom_sf(
    data = stationsWGS84,
    colour = "grey60",
    size = 0.35,
    alpha = 0.6
  ) +
  geom_sf(
    data = catchmentWGS84,
    fill = "firebrick",
    colour = "firebrick",
    alpha = 0.45,
    linewidth = 0.5
  ) +
  geom_sf(
    data = stationWGS84,
    colour = "black",
    size = 1.8
  ) +
  coord_sf(
    expand = FALSE
  ) +
  labs(
    title = "Location in New Zealand"
  ) +
  themeMap

bb <- st_bbox(
  catchmentWGS84
)

dx <- as.numeric(
  bb["xmax"] -
    bb["xmin"]
)

dy <- as.numeric(
  bb["ymax"] -
    bb["ymin"]
)

padX <- max(
  dx * 0.15,
  0.02
)

padY <- max(
  dy * 0.15,
  0.02
)

pMapBasin <- ggplot() +
  geom_sf(
    data = catchmentWGS84,
    fill = "grey90",
    colour = "grey20",
    linewidth = 0.7
  ) +
  geom_sf(
    data = stationWGS84,
    colour = "black",
    size = 2.5
  ) +
  coord_sf(
    xlim = c(
      bb["xmin"] - padX,
      bb["xmax"] + padX
    ),
    ylim = c(
      bb["ymin"] - padY,
      bb["ymax"] + padY
    ),
    expand = FALSE
  ) +
  labs(
    title = paste(
      "Catchment",
      ID
    )
  ) +
  themeMap


# ==============================================================================
# Summary diagnostics
# ==============================================================================

pDuration <- ggplot(
  ev,
  aes(duration_h)
) +
  geom_histogram(
    bins = 30,
    fill = "grey80",
    colour = "grey30"
  ) +
  geom_vline(
    xintercept = median(
      ev$duration_h,
      na.rm = TRUE
    ),
    linetype = "dashed",
    colour = "firebrick"
  ) +
  labs(
    title = "Selected event duration",
    x = "Duration [h]",
    y = "Number of events"
  ) +
  themeSummary

pPeak <- ggplot(
  ev,
  aes(peak_over_q99)
) +
  geom_histogram(
    bins = 30,
    fill = "grey80",
    colour = "grey30"
  ) +
  geom_vline(
    xintercept = 1,
    linetype = "dashed",
    colour = "firebrick"
  ) +
  labs(
    title = "Selected flood magnitude",
    x = "Peak Qobs / Q99",
    y = "Number of events"
  ) +
  themeSummary

yearCounts <- aggregate(
  event_id ~ year,
  data = ev,
  FUN = length
)

names(yearCounts)[2] <- "n_events"

pYear <- ggplot(
  yearCounts,
  aes(
    year,
    n_events
  )
) +
  geom_col(
    fill = "grey70",
    colour = "grey30"
  ) +
  scale_x_continuous(
    breaks = pretty(
      range(
        yearCounts$year
      ),
      n = 7
    )
  ) +
  labs(
    title = "Selected events through time",
    x = "Year",
    y = "Number of events"
  ) +
  themeSummary

pScatter <- ggplot(
  ev,
  aes(
    duration_h,
    peak_over_q99,
    shape = event_type
  )
) +
  geom_point(
    size = 2,
    alpha = 0.75
  ) +
  labs(
    title = "Duration versus flood magnitude",
    x = "Duration [h]",
    y = "Peak Qobs / Q99",
    shape = NULL
  ) +
  themeSummary +
  theme(
    legend.position = "bottom"
  )


# ==============================================================================
# Individual event plot
# ==============================================================================

make_event_plot <- function(e) {

  contextH <- 48

  t1 <- (
    e$start_time -
      contextH * 3600
  )

  t2 <- (
    e$end_time +
      contextH * 3600
  )

  d <- hydro[
    hydro$time >= t1 &
      hydro$time <= t2,
    ,
    drop = FALSE
  ]



  spanH <- as.numeric(
    difftime(
      t2,
      t1,
      units = "hours"
    )
  )

  dateBreaks <- if (
    spanH <= 120
  ) {
    "12 hours"
  } else if (
    spanH <= 240
  ) {
    "1 day"
  } else {
    "2 days"
  }


  subtitle <- paste0(
    "Duration: ", round(e$duration_h), " h",
    " | Peak Qobs: ", fmt(e$peak_q_obs, 3), " mm/h"
  )

  if (hasQC) {
    reviewReasons <- text_value(e, "review_reasons")

    if (!nzchar(reviewReasons)) {
      reviewReasons <- text_value(e, "quick_review_reasons")
    }

    if (nzchar(reviewReasons)) {
      subtitle <- paste0(
        subtitle,
        "\nQC: ",
        gsub(";", ", ", reviewReasons, fixed = TRUE)
      )
    }
  }


  # ---------------------------------------------------------------------------
  # Plot
  # ---------------------------------------------------------------------------

  p <- ggplot(
    d,
    aes(
      time,
      q
    )
  )


  # Final flood-event window.

  p <- p +
    annotate(
      "rect",
      xmin = e$start_time,
      xmax = e$end_time,
      ymin = -Inf,
      ymax = Inf,
      fill = "steelblue",
      alpha = 0.10
    )


  # Raw Qobs.

  p <- p +
    geom_line(
      linewidth = 0.4,
      na.rm = TRUE
    )


  # Q99 threshold.

  p <- p +
    geom_hline(
      yintercept = e$q99,
      linetype = "dashed",
      colour = "firebrick",
      linewidth = 0.4
    )


  # Event boundaries.

  p <- p +
    geom_vline(
      xintercept = as.numeric(
        c(
          e$start_time,
          e$end_time
        )
      ),
      colour = "steelblue4",
      linetype = "dotted",
      linewidth = 0.4
    )


  # Observed event peak.

  p <- p +
    geom_point(
      data = data.frame(
        time = e$peak_time_obs,
        q = e$peak_q_obs
      ),
      aes(
        time,
        q
      ),
      inherit.aes = FALSE,
      colour = "firebrick",
      size = if (hasQC) 2 else 1.4
    )





  p +
    scale_x_datetime(
      timezone = experiment$timezone,
      date_breaks = dateBreaks,
      date_labels = "%m-%d\n%H:%M",
      expand = expansion(
        mult = c(
          0.01,
          0.01
        )
      )
    ) +
    scale_y_continuous(
      expand = expansion(
        mult = c(
          0.02,
          0.08
        )
      )
    ) +
    labs(
      title = paste0(
        "Basin ", ID, ", peak: ",
        paste0(
          format(e$peak_time_obs, "%Y-%m-%d %H:%M", tz = experiment$timezone),
          " NZST (UTC+12)"
        )
      ),
      subtitle = subtitle,
      x = NULL,
      y = "Qobs [mm/h]"
    ) +
    themeEvent
}


# ==============================================================================
# Write PDF
# ==============================================================================

dir.create(
  dirname(fileOut),
  recursive = TRUE,
  showWarnings = FALSE
)

pdf(
  fileOut,
  width = 16.54,
  height = 11.69,
  onefile = TRUE
)


# Page 1: basin and selected-event summary.

grid.newpage()

pushViewport(
  viewport(
    layout = grid.layout(
      nrow = 3,
      ncol = 4,
      widths = unit(
        c(
          1.15,
          1,
          1,
          1
        ),
        "null"
      ),
      heights = unit(
        c(
          1.05,
          1,
          1
        ),
        "null"
      )
    )
  )
)

pushViewport(
  viewport(
    layout.pos.row = 1:3,
    layout.pos.col = 1
  )
)

grid.draw(
  summaryGrob
)

popViewport()


place_plot <- function(
  p,
  row,
  col
) {

  print(
    p,
    vp = viewport(
      layout.pos.row = row,
      layout.pos.col = col
    ),
    newpage = FALSE
  )
}

place_plot(
  pMapNZ,
  1,
  2
)

place_plot(
  pMapBasin,
  1,
  3
)

place_plot(
  pYear,
  1,
  4
)

place_plot(
  pDuration,
  2,
  2:3
)

place_plot(
  pPeak,
  2,
  4
)

place_plot(
  pScatter,
  3,
  2:4
)

popViewport()


# QC event sets use larger hydrographs.

if (hasQC) {

  plotRows <- 2L
  plotCols <- 2L

} else {

  plotRows <- 4L
  plotCols <- 4L
}

eventsPerPage <- (
  plotRows *
    plotCols
)

eventPlots <- lapply(
  seq_len(
    nrow(ev)
  ),
  function(i) {

    make_event_plot(
      ev[
        i,
        ,
        drop = FALSE
      ]
    )
  }
)

for (s in seq(
  1L,
  length(eventPlots),
  by = eventsPerPage
)) {

  ii <- s:min(
    s +
      eventsPerPage -
      1L,
    length(eventPlots)
  )

  print_grid(
    eventPlots[ii],
    nrow = plotRows,
    ncol = plotCols
  )
}

dev.off()


# ==============================================================================
# Console summary
# ==============================================================================

nEventPages <- ceiling(
  nrow(ev) /
    eventsPerPage
)

cat(
  "\n",
  "Basin            : ", ID, "\n",
  "Station          : ", stationName, "\n",
  "Input event file : ", fileEvents, "\n",
  "Canonical events : ", nrow(canonical), "\n",
  "Events shown     : ", nrow(ev), "\n",
  "QC annotations   : ", hasQC, "\n",
  "Events/page      : ", eventsPerPage, "\n",
  "Pages            : ", 1L + nEventPages, "\n",
  "PDF              : ", fileOut, "\n",
  sep = ""
)
