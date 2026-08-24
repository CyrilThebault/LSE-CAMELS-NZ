#!/usr/bin/env Rscript

# ==============================================================================
# Prepare CAMELS-NZ forcing files for lumped daily FUSE runs
#
# For each selected basin, this script:
#   - reads catchment metadata and daily CAMELS-NZ time series,
#   - aligns meteorological forcing and streamflow to the simulation period,
#   - converts observed discharge from m3/s to mm/day,
#   - writes the lumped FUSE forcing NetCDF file,
#   - writes a single-band elevation file for the lumped configuration.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2L) {
  stop("Usage: Rscript 01_prepare_CAMELS_NZ.R <basinID|ALL> <dirMain>")
}

basin_arg <- args[1]
dirMain <- normalizePath(args[2], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/basins.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain)

suppressPackageStartupMessages(library(ncdf4))


# ==============================================================================
# Basins to prepare
# ==============================================================================

basin_file <- file.path(dirMain, "config", "basins.txt")

if (!file.exists(basin_file)) {
  stop("Create config/basins.txt from config/basins.txt.example")
}

basins <- if (toupper(basin_arg) == "ALL") {
  read_basin_ids(basin_file)
} else {
  as.character(basin_arg)
}


# ==============================================================================
# CAMELS-NZ catchment metadata
# ==============================================================================

attr_dir <- file.path(experiment$paths$camels_nz, "CAMELS_NZ_Catchment_Atrributes")

metadata <- read.csv(
  file.path(attr_dir, "1.CAMELS_NZ_Catchment_information.csv"),
  fileEncoding = "UTF-8-BOM",
  stringsAsFactors = FALSE,
  check.names = FALSE
)

if (!"Station_ID" %in% names(metadata)) {
  stop("Station_ID missing from CAMELS-NZ catchment information")
}

# Column names differ slightly between CAMELS-NZ file versions, so use the first
# recognised name while still failing explicitly if none are present.
pick_col <- function(df, candidates) {
  
  hit <- candidates[candidates %in% names(df)]
  
  if (!length(hit)) {
    stop("None of the required columns found: ", paste(candidates, collapse = ", "))
  }
  
  hit[1]
}

lat_col <- pick_col(metadata, c("Latitude (WGS 84)", "Latitude..WGS.84."))
lon_col <- pick_col(metadata, c("Longitude(WGS 84)", "Longitude.WGS.84."))
area_col <- pick_col(metadata, c("uparea", "Area", "area"))
elev_col <- pick_col(metadata, c("elevation", "Elevation"))


# ==============================================================================
# Read and align one CAMELS-NZ time series
#
# All forcing variables are aligned explicitly to the FUSE simulation dates so
# that gaps or shifted periods cannot silently propagate into the NetCDF files.
# ==============================================================================

read_aligned <- function(file, value_col, dates) {
  
  if (!file.exists(file)) {
    stop("Missing CAMELS-NZ file: ", file)
  }
  
  x <- read.csv(file, stringsAsFactors = FALSE, check.names = FALSE)
  
  if (!all(c("time", value_col) %in% names(x))) {
    stop("Missing time/", value_col, " in ", file)
  }
  
  x$time <- as.POSIXct(x$time, tz = "Etc/GMT-12")
  
  x[[value_col]][match(dates, x$time)]
}


# ==============================================================================
# Prepare each basin
# ==============================================================================

for (catchment in basins) {
  
  message("Preparing basin ", catchment)
  
  row <- which(as.character(metadata$Station_ID) == catchment)
  
  if (length(row) != 1L) {
    stop("Expected one metadata row for ", catchment)
  }
  
  lat <- as.numeric(metadata[row, lat_col])
  lon <- as.numeric(metadata[row, lon_col])
  area_km2 <- as.numeric(metadata[row, area_col])
  elevation <- as.numeric(metadata[row, elev_col])
  
  dates <- seq.POSIXt(
    as.POSIXct(paste(experiment$simulation_start, "00:00:00"), tz = "Etc/GMT-12"),
    as.POSIXct(paste(experiment$simulation_end, "00:00:00"), tz = "Etc/GMT-12"),
    by = "1 day"
  )
  
  base <- experiment$paths$camels_nz
  
  # Daily meteorological forcing and observed discharge
  pr <- read_aligned(
    file.path(base, "CAMELS_NZ_daily_Precipitation",
              paste0("daily_precipitation_station_id_", catchment, ".csv")),
    "precipitation",
    dates
  )
  
  temp <- read_aligned(
    file.path(base, "CAMELS_NZ_daily_Temperature",
              paste0("daily_temperature_station_id_", catchment, ".csv")),
    "temperature",
    dates
  ) - 273.15
  
  pet <- read_aligned(
    file.path(base, "CAMELS_NZ_daily_PET",
              paste0("daily_PET_station_id_", catchment, ".csv")),
    "PET",
    dates
  )
  
  flow <- read_aligned(
    file.path(base, "CAMELS_NZ_daily_Streamflow",
              paste0("daily_flow_station_id_", catchment, ".csv")),
    "flow",
    dates
  )
  
  if (anyNA(pr) || anyNA(temp) || anyNA(pet)) {
    stop("Missing meteorological forcing(s) for basin ", catchment)
  }
  
  # Negative precipitation and PET are not physically meaningful
  pr[pr < 0] <- 0
  pet[pet < 0] <- 0
  
  # Convert observed streamflow from m3/s to catchment-average mm/day
  qobs <- flow * 86400 / (area_km2 * 1e6) * 1000
  qobs[qobs < 0] <- NA_real_
  
  
  # ============================================================================
  # Main FUSE forcing file
  # ============================================================================
  
  outdir <- ensure_dir(file.path(paths$forcings, catchment))
  inputname <- file.path(outdir, paste0(catchment, "_input.nc"))
  
  latdim <- ncdim_def("latitude", "degreesN", lat)
  londim <- ncdim_def("longitude", "degreesE", lon)
  timedim <- ncdim_def(
    "time",
    paste0("days since ", experiment$simulation_start),
    0:(length(dates) - 1),
    unlim = TRUE
  )
  nobsdim <- ncdim_def("nobs", "", 1L, create_dimvar = FALSE)
  
  PET_def <- ncvar_def("pet", "mm/day", list(londim, latdim, timedim), prec = "double")
  P_def <- ncvar_def("pr", "mm/day", list(londim, latdim, timedim), prec = "double")
  Q_def <- ncvar_def("q_obs", "mm/day", list(nobsdim, timedim), missval = -9999, prec = "double")
  T_def <- ncvar_def("temp", "degC", list(londim, latdim, timedim), prec = "double")
  A_def <- ncvar_def("basin_area", "km2", list(), prec = "float")
  
  nc <- nc_create(inputname, list(PET_def, P_def, Q_def, T_def, A_def), force_v4 = TRUE)
  
  ncvar_put(nc, PET_def, array(pet, c(1, 1, length(pet))))
  ncvar_put(nc, P_def, array(pr, c(1, 1, length(pr))))
  ncvar_put(nc, Q_def, array(qobs, c(1, length(qobs))))
  ncvar_put(nc, T_def, array(temp, c(1, 1, length(temp))))
  ncvar_put(nc, A_def, area_km2)
  
  ncatt_put(nc, 0, "workflow", "CAMELS-NZ lumped daily LSE")
  nc_close(nc)
  
  
  # ============================================================================
  # Elevation-band file
  #
  # The present workflow is lumped, so the full catchment is represented by one
  # elevation band with unit area and precipitation fractions.
  # ============================================================================
  
  elevname <- file.path(outdir, paste0(catchment, "_elev_bands.nc"))
  
  edim <- ncdim_def("elevation_band", "-", 1L)
  
  af <- ncvar_def("area_frac", "-", list(londim, latdim, edim), prec = "double")
  me <- ncvar_def("mean_elev", "m asl", list(londim, latdim, edim), prec = "double")
  pf <- ncvar_def("prec_frac", "-", list(londim, latdim, edim), prec = "double")
  
  nc <- nc_create(elevname, list(af, me, pf), force_v4 = TRUE)
  
  ncvar_put(nc, af, array(1, c(1, 1, 1)))
  ncvar_put(nc, me, array(elevation, c(1, 1, 1)))
  ncvar_put(nc, pf, array(1, c(1, 1, 1)))
  
  nc_close(nc)
}