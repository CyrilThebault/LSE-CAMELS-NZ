#!/usr/bin/env Rscript

library(ncdf4)
library(ggplot2)
library(grid)
library(sf)

# ==============================================================================
# Arguments
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: Rscript 02_review_observed_flood_catalogue.R <dirMain> <ID> <output.pdf>")
}

dirMain <- normalizePath(args[1], mustWork = TRUE)
ID      <- as.character(args[2])
fileOut <- args[3]

# ==============================================================================
# Helpers
# ==============================================================================

decode_time <- function(x, units) {
  z <- regmatches(
    units,
    regexec("^\\s*(seconds|minutes|hours|days)\\s+since\\s+(.+?)\\s*$",
            units, ignore.case = TRUE)
  )[[1]]
  stopifnot(length(z) == 3L)

  origin <- sub("\\s+(UTC|GMT)$", "", trimws(z[3]), ignore.case = TRUE)
  mult <- switch(tolower(z[2]), seconds = 1, minutes = 60, hours = 3600, days = 86400)
  as.POSIXct(origin, tz = "UTC") + x * mult
}

parse_time <- function(x) {
  as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
}

parse_cols <- function(x, cols) {
  for (v in intersect(cols, names(x))) x[[v]] <- parse_time(x[[v]])
  x
}

print_grid <- function(plots, nrow, ncol) {
  grid.newpage()
  pushViewport(viewport(layout = grid.layout(nrow, ncol)))
  for (i in seq_along(plots)) {
    row <- ((i - 1L) %/% ncol) + 1L
    col <- ((i - 1L) %% ncol) + 1L
    print(
      plots[[i]],
      vp = viewport(layout.pos.row = row, layout.pos.col = col),
      newpage = FALSE
    )
  }
  popViewport()
}

matches_id <- function(x, id) {
  x_chr  <- trimws(as.character(x))
  id_chr <- trimws(as.character(id))
  out <- x_chr == id_chr

  id_num <- suppressWarnings(as.numeric(id_chr))
  x_num  <- suppressWarnings(as.numeric(x_chr))
  if (!is.na(id_num)) out <- out | (!is.na(x_num) & x_num == id_num)
  out
}

# Find the catchment attribute containing the requested basin ID.
find_id_column <- function(x, id) {
  preferred <- c(
    "Station_ID", "station_id", "STATION_ID", "StationID", "stationid",
    "Site_ID", "site_id", "SITE_ID", "ID", "Id", "id", "RID"
  )
  attributes <- setdiff(names(x), attr(x, "sf_column"))

  for (nm in intersect(preferred, attributes)) {
    if (any(matches_id(x[[nm]], id), na.rm = TRUE)) return(nm)
  }

  hits <- attributes[vapply(attributes, function(nm) {
    !is.list(x[[nm]]) && any(matches_id(x[[nm]], id), na.rm = TRUE)
  }, logical(1))]

  if (length(hits) == 1L) return(hits)
  if (length(hits) > 1L) {
    stop(
      "Basin ID ", id, " was found in several catchment attributes: ",
      paste(hits, collapse = ", "), "\nAvailable columns: ",
      paste(attributes, collapse = ", ")
    )
  }
  stop(
    "Could not find basin ID ", id, " in All_Nested_Catchments.shp.",
    "\nAvailable columns: ", paste(attributes, collapse = ", ")
  )
}

# Compact five-number summary used on the first page.
summary_stats <- function(x) {
  c(
    min    = min(x, na.rm = TRUE),
    p05    = unname(quantile(x, 0.05, na.rm = TRUE)),
    median = median(x, na.rm = TRUE),
    p95    = unname(quantile(x, 0.95, na.rm = TRUE)),
    max    = max(x, na.rm = TRUE)
  )
}

# ==============================================================================
# Input files
# ==============================================================================

file_catalogue  <- file.path(dirMain, "data", "flood", "observed_flood_catalogue.csv")
file_candidates <- file.path(dirMain, "data", "flood", "diagnostics", "observed_flood_candidates.csv")
file_excluded   <- file.path(dirMain, "data", "flood", "diagnostics", "observed_flood_excluded.csv")
file_nc         <- file.path(dirMain, "data", "forcings", "hourly", ID, paste0(ID, "_input.nc"))
file_stations   <- file.path(dirMain, "shapefiles", "camel_stationsNZ.shp")
file_nz         <- file.path(dirMain, "shapefiles", "nz.shp")
file_catchments <- file.path(dirMain, "shapefiles", "All_Nested_Catchments.shp")

files_required <- c(
  file_catalogue, file_candidates, file_excluded, file_nc,
  file_stations, file_nz, file_catchments
)
stopifnot(all(file.exists(files_required)))

# ==============================================================================
# Flood catalogue
# ==============================================================================

catalogue  <- read.csv(file_catalogue, stringsAsFactors = FALSE)
candidates <- read.csv(file_candidates, stringsAsFactors = FALSE)
excluded   <- read.csv(file_excluded, stringsAsFactors = FALSE)

catalogue$ID  <- as.character(catalogue$ID)
candidates$ID <- as.character(candidates$ID)
excluded$ID   <- as.character(excluded$ID)

catalogue <- parse_cols(catalogue, c(
  "start_time", "end_time", "peak_time_obs",
  "first_candidate_time", "last_candidate_time"
))
candidates <- parse_cols(candidates, c(
  "candidate_time", "eventmax_start", "eventmax_end", "bfi_start", "bfi_end"
))
excluded <- parse_cols(excluded, c("candidate_time", "eventmax_start", "eventmax_end"))

ev   <- catalogue[catalogue$ID == ID, , drop = FALSE]
cand <- candidates[candidates$ID == ID, , drop = FALSE]
exc  <- excluded[excluded$ID == ID, , drop = FALSE]

if (!nrow(ev)) stop("No catalogue events found for basin ", ID)
ev <- ev[order(ev$start_time), , drop = FALSE]
rownames(ev) <- NULL

# ==============================================================================
# Hourly observed discharge
# ==============================================================================

nc <- nc_open(file_nc)
q <- as.numeric(ncvar_get(nc, "q_obs"))
time <- decode_time(nc$dim$time$vals, nc$dim$time$units)
nc_close(nc)
hydro <- data.frame(time, q)

# ==============================================================================
# Spatial data
# ==============================================================================

stations_sf   <- st_read(file_stations, quiet = TRUE)
nz_sf         <- st_read(file_nz, quiet = TRUE)
catchments_sf <- st_read(file_catchments, quiet = TRUE)

stations_sf$Station_ID <- as.character(stations_sf$Station_ID)
station_sf <- stations_sf[stations_sf$Station_ID == ID, , drop = FALSE]
if (nrow(station_sf) != 1L) {
  stop("Expected exactly one station for basin ", ID, ", found ", nrow(station_sf))
}

catchment_id_col <- find_id_column(catchments_sf, ID)
cat("Catchment ID field:", catchment_id_col, "\n")
catchment_sf <- catchments_sf[
  matches_id(catchments_sf[[catchment_id_col]], ID), , drop = FALSE
]
if (nrow(catchment_sf) != 1L) {
  stop(
    "Expected exactly one catchment polygon for basin ", ID,
    " using column ", catchment_id_col, ", found ", nrow(catchment_sf)
  )
}

# WGS84 for all maps.
stations_wgs84  <- st_transform(stations_sf, 4326)
station_wgs84   <- stations_wgs84[stations_wgs84$Station_ID == ID, , drop = FALSE]
catchment_wgs84 <- st_transform(catchment_sf, 4326)
nz_wgs84        <- st_transform(nz_sf, 4326)

# ==============================================================================
# Basin and flood diagnostics
# ==============================================================================

ev$year <- as.integer(format(ev$peak_time_obs, "%Y"))
ev$event_type <- ifelse(
  ev$n_q99_candidates > 1, "Multiple Q99 peaks", "Single Q99 peak"
)

station_name <- as.character(station_sf$Station_Na[1])
uparea <- as.numeric(station_sf$uparea[1])
elevation <- as.numeric(station_sf$elevation[1])
stream_order <- as.numeric(station_sf$Stream_Ord[1])
total_observed_records <- as.numeric(station_sf$Records[1])

record_start <- min(hydro$time, na.rm = TRUE)
record_end   <- max(hydro$time, na.rm = TRUE)
record_years <- as.numeric(difftime(record_end, record_start, units = "days")) / 365.25
events_per_year <- nrow(ev) / record_years

n_multi <- sum(ev$n_q99_candidates > 1)
multi_pct <- 100 * n_multi / nrow(ev)

duration_stats  <- summary_stats(ev$duration_h)
peakratio_stats <- summary_stats(ev$peak_over_q99)
volume_stats    <- summary_stats(ev$volume_obs_mm)

# ==============================================================================
# Plot themes
# ==============================================================================

theme_summary <- theme_bw(base_size = 10) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    plot.title = element_text(face = "bold", size = 11),
    axis.title = element_text(size = 9),
    axis.text = element_text(size = 8),
    plot.margin = margin(5, 5, 5, 5)
  )

theme_review <- theme_bw(base_size = 7) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    plot.title = element_text(size = 7.5, face = "bold", margin = margin(b = 1)),
    plot.subtitle = element_text(size = 5.8, margin = margin(b = 2)),
    axis.title = element_text(size = 6.5),
    axis.text = element_text(size = 5.5),
    plot.margin = margin(4, 4, 4, 4)
  )

theme_map <- theme_void() +
  theme(
    plot.title = element_text(face = "bold", size = 11),
    panel.border = element_rect(colour = "grey30", fill = NA, linewidth = 0.7),
    plot.margin = margin(5, 5, 5, 5)
  )

# ==============================================================================
# First-page summary
# ==============================================================================

reason_text <- if (nrow(exc)) {
  tab <- sort(table(exc$exclude_reason), decreasing = TRUE)
  paste(paste0(names(tab), ": ", as.integer(tab)), collapse = "\n")
} else {
  "None"
}

fmt_stats <- function(x, digits, unit = "") {
  paste0(
    "Minimum: ", round(x["min"], digits), unit,
    "\nP05: ", round(x["p05"], digits), unit,
    "\nMedian: ", round(x["median"], digits), unit,
    "\nP95: ", round(x["p95"], digits), unit,
    "\nMaximum: ", round(x["max"], digits), unit
  )
}

summary_sections <- list(
  list(
    title = "Station",
    content = paste0(
      station_name,
      "\nStation ID: ", ID,
      "\nUpstream area: ", round(uparea, 1), " km2",
      "\nElevation: ", round(elevation, 1), " m a.s.l.",
      "\nStream order: ", stream_order,
      "\nTotal observed records: ", round(total_observed_records, 1), " years"
    )
  ),
  list(
    title = "Observed record used",
    content = paste0(
      "Start: ", format(record_start, "%Y-%m-%d"),
      "\nEnd: ", format(record_end, "%Y-%m-%d"),
      "\nLength: ", round(record_years, 1), " years"
    )
  ),
  list(
    title = "Flood catalogue",
    content = paste0(
      "Events: ", nrow(ev),
      "\nEvents/year: ", round(events_per_year, 2),
      "\nQ99: ", format(ev$q99[1], digits = 5), " mm/h"
    )
  ),
  list(title = "Event duration", content = fmt_stats(duration_stats, 1, " h")),
  list(title = "Peak / Q99", content = fmt_stats(peakratio_stats, 2)),
  list(title = "Event volume", content = fmt_stats(volume_stats, 1, " mm")),
  list(
    title = "Multi-peaks",
    content = paste0("Events: ", n_multi, "\nPercentage: ", round(multi_pct, 1), "%")
  ),
  list(
    title = "Events excluded",
    content = paste0("Candidates: ", nrow(exc), if (nrow(exc)) paste0("\n", reason_text) else "")
  )
)

# Grid measures each text block, so spacing stays constant regardless of line count.
make_summary_grob <- function(sections) {
  grobs <- list()
  add <- function(g) grobs[[length(grobs) + 1L]] <<- g

  x_left <- unit(0.02, "npc")
  y <- unit(0.99, "npc")
  line_gap <- unit(4.2, "mm")

  title <- textGrob(
    "Observed flood catalogue", x = x_left, y = y, just = c("left", "top"),
    gp = gpar(fontsize = 16, fontface = "bold")
  )
  add(title)
  y <- y - grobHeight(title) - 3 * line_gap

  for (section in sections) {
    heading <- textGrob(
      section$title, x = x_left, y = y, just = c("left", "top"),
      gp = gpar(fontsize = 11.5, fontface = "bold")
    )
    add(heading)
    y <- y - grobHeight(heading) - line_gap

    content <- textGrob(
      section$content, x = x_left, y = y, just = c("left", "top"),
      gp = gpar(fontsize = 10.5, lineheight = 1.03)
    )
    add(content)
    y <- y - grobHeight(content) - 2 * line_gap
  }

  do.call(grobTree, grobs)
}

summary_grob <- make_summary_grob(summary_sections)

# ==============================================================================
# First-page maps
# ==============================================================================

p_map_nz <- ggplot() +
  geom_sf(data = nz_wgs84, fill = "grey95", colour = "grey55", linewidth = 0.25) +
  geom_sf(data = stations_wgs84, colour = "grey60", size = 0.35, alpha = 0.6) +
  geom_sf(
    data = catchment_wgs84, fill = "firebrick", colour = "firebrick",
    alpha = 0.45, linewidth = 0.5
  ) +
  geom_sf(data = station_wgs84, colour = "black", size = 1.8) +
  coord_sf(expand = FALSE) +
  labs(title = "Location in New Zealand") +
  theme_map

bb <- st_bbox(catchment_wgs84)
dx <- as.numeric(bb["xmax"] - bb["xmin"])
dy <- as.numeric(bb["ymax"] - bb["ymin"])
pad_x <- max(dx * 0.15, 0.02)
pad_y <- max(dy * 0.15, 0.02)

p_map_basin <- ggplot() +
  geom_sf(data = catchment_wgs84, fill = "grey90", colour = "grey20", linewidth = 0.7) +
  geom_sf(data = station_wgs84, colour = "black", size = 2.5) +
  coord_sf(
    xlim = c(bb["xmin"] - pad_x, bb["xmax"] + pad_x),
    ylim = c(bb["ymin"] - pad_y, bb["ymax"] + pad_y),
    expand = FALSE
  ) +
  labs(title = paste("Catchment", ID)) +
  theme_map

# ==============================================================================
# First-page diagnostics
# ==============================================================================

p_duration <- ggplot(ev, aes(duration_h)) +
  geom_histogram(bins = 30, fill = "grey80", colour = "grey30") +
  geom_vline(
    xintercept = median(ev$duration_h, na.rm = TRUE),
    linetype = "dashed", colour = "firebrick"
  ) +
  labs(title = "Event duration", x = "Duration [h]", y = "Number of events") +
  theme_summary

p_peak <- ggplot(ev, aes(peak_over_q99)) +
  geom_histogram(bins = 30, fill = "grey80", colour = "grey30") +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "firebrick") +
  labs(
    title = "Flood magnitude relative to Q99",
    x = "Peak Qobs / Q99", y = "Number of events"
  ) +
  theme_summary

year_counts <- aggregate(event_id ~ year, data = ev, FUN = length)
names(year_counts)[2] <- "n_events"

p_year <- ggplot(year_counts, aes(year, n_events)) +
  geom_col(fill = "grey70", colour = "grey30") +
  scale_x_continuous(breaks = pretty(range(year_counts$year), n = 7)) +
  labs(title = "Flood events through time", x = "Year", y = "Number of events") +
  theme_summary

p_scatter <- ggplot(ev, aes(duration_h, peak_over_q99, shape = event_type)) +
  geom_point(size = 2, alpha = 0.75) +
  labs(
    title = "Duration versus flood magnitude",
    x = "Duration [h]", y = "Peak Qobs / Q99", shape = NULL
  ) +
  theme_summary +
  theme(legend.position = "bottom")

# ==============================================================================
# Individual event plot
# ==============================================================================

make_event_plot <- function(e) {
  context_h <- 48
  t1 <- e$start_time - context_h * 3600
  t2 <- e$end_time + context_h * 3600

  d <- hydro[hydro$time >= t1 & hydro$time <= t2, , drop = FALSE]
  cc <- cand[
    cand$candidate_time >= e$start_time & cand$candidate_time <= e$end_time,
    , drop = FALSE
  ]

  span_h <- as.numeric(difftime(t2, t1, units = "hours"))
  date_breaks <- if (span_h <= 120) "12 hours" else if (span_h <= 240) "1 day" else "2 days"

  subtitle <- paste0(
    "duration=", round(e$duration_h),
    " h | peak/Q99=", round(e$peak_over_q99, 2),
    " | Q99=", format(e$q99, digits = 4), " mm/h",
    " | candidates=", e$n_q99_candidates,
    " | ", e$quality_flag
  )

  ggplot(d, aes(time, q)) +
    annotate(
      "rect", xmin = e$start_time, xmax = e$end_time,
      ymin = -Inf, ymax = Inf, fill = "steelblue", alpha = 0.10
    ) +
    geom_line(linewidth = 0.4, na.rm = TRUE) +
    geom_hline(
      yintercept = e$q99, linetype = "dashed",
      colour = "firebrick", linewidth = 0.4
    ) +
    geom_vline(
      xintercept = as.numeric(c(e$start_time, e$end_time)),
      colour = "steelblue4", linetype = "dotted", linewidth = 0.4
    ) +
    geom_point(
      data = data.frame(time = e$peak_time_obs, q = e$peak_q_obs),
      aes(time, q), inherit.aes = FALSE, colour = "firebrick", size = 1.4
    ) +
    geom_point(
      data = cc, aes(candidate_time, candidate_q_obs), inherit.aes = FALSE,
      colour = "darkorange3", shape = 21, fill = NA, stroke = 0.8, size = 1.8
    ) +
    scale_x_datetime(
      date_breaks = date_breaks, date_labels = "%m-%d\n%H:%M",
      expand = expansion(mult = c(0.01, 0.01))
    ) +
    scale_y_continuous(expand = expansion(mult = c(0.02, 0.08))) +
    labs(
      title = format(e$start_time, "%Y-%m-%d %H:%M UTC"),
      subtitle = subtitle, x = NULL, y = "Qobs [mm/h]"
    ) +
    theme_review
}

# ==============================================================================
# Write PDF
# ==============================================================================

dir.create(dirname(fileOut), recursive = TRUE, showWarnings = FALSE)
pdf(fileOut, width = 16.54, height = 11.69, onefile = TRUE)

# Page 1: basin and catalogue summary.
grid.newpage()
pushViewport(viewport(
  layout = grid.layout(
    nrow = 3, ncol = 4,
    widths = unit(c(1.15, 1, 1, 1), "null"),
    heights = unit(c(1.05, 1, 1), "null")
  )
))

# Left column.
pushViewport(viewport(layout.pos.row = 1:3, layout.pos.col = 1))
grid.draw(summary_grob)
popViewport()

# Remaining first-page panels.
place_plot <- function(p, row, col) {
  print(
    p,
    vp = viewport(layout.pos.row = row, layout.pos.col = col),
    newpage = FALSE
  )
}

place_plot(p_map_nz,    1,   2)
place_plot(p_map_basin, 1,   3)
place_plot(p_year,      1,   4)
place_plot(p_duration,  2, 2:3)
place_plot(p_peak,      2,   4)
place_plot(p_scatter,   3, 2:4)
popViewport()

# Remaining pages: all observed flood events, 4 x 4 per page.
event_plots <- lapply(seq_len(nrow(ev)), function(i) make_event_plot(ev[i, , drop = FALSE]))
events_per_page <- 16L
for (s in seq(1L, length(event_plots), by = events_per_page)) {
  ii <- s:min(s + events_per_page - 1L, length(event_plots))
  print_grid(event_plots[ii], nrow = 4, ncol = 4)
}

dev.off()

# ==============================================================================
# Console summary
# ==============================================================================

n_event_pages <- ceiling(nrow(ev) / events_per_page)
cat(
  "\n",
  "Basin        : ", ID, "\n",
  "Station      : ", station_name, "\n",
  "Events       : ", nrow(ev), "\n",
  "Excluded     : ", nrow(exc), "\n",
  "Multi-peak   : ", n_multi, "\n",
  "Events shown : ", nrow(ev), "\n",
  "Pages        : ", 1L + n_event_pages, "\n",
  "PDF          : ", fileOut, "\n",
  sep = ""
)