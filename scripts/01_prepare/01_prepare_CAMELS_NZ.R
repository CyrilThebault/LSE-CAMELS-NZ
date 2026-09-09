#!/usr/bin/env Rscript

# ==============================================================================
# Prepare CAMELS-NZ forcing files for lumped FUSE runs
#
# For each selected basin, this script:
#   - reads catchment metadata and CAMELS-NZ time series,
#   - aligns meteorological forcing and streamflow to the simulation period,
#   - converts observed discharge from m3/s to catchment-average water depth,
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
time_info <- get_timestep_info(experiment)
paths <- project_paths(dirMain, experiment)

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
  fileEncoding = "UTF-8-BOM", stringsAsFactors = FALSE, check.names = FALSE)

if (!"Station_ID" %in% names(metadata)) {
  stop("Station_ID missing from CAMELS-NZ catchment information")
}

# ==============================================================================
# Read and align one CAMELS-NZ time series
#
# All forcing variables are aligned explicitly to the FUSE simulation dates so
# that gaps or shifted periods cannot silently propagate into the NetCDF files.
# ==============================================================================

read_aligned <- function(file, value_col, dates, timezone) {
  
  if (!file.exists(file)) {
    stop("Missing CAMELS-NZ file: ", file)
  }
  
  x <- read.csv(file, stringsAsFactors = FALSE, check.names = FALSE)
  
  if (!all(c("time", value_col) %in% names(x))) {
    stop("Missing time/", value_col, " in ", file)
  }
  
  x$time <- as.POSIXct(x$time, tz = timezone)
  
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
  
  lat <- as.numeric(metadata[row, "Latitude (WGS 84)"])
  lon <- as.numeric(metadata[row, "Longitude(WGS 84)"])
  area_km2 <- as.numeric(metadata[row, "uparea"])
  elevation <- as.numeric(metadata[row, "elevation"])
  
  dates <- seq.POSIXt(from = experiment$simulation_start, to = experiment$simulation_end, by = time_info$time_units)
  
  base <- experiment$paths$camels_nz
  
  prefix <- experiment$timestep
  file_prefix <- ifelse (experiment$timestep == "daily", "daily_", "")
  
  # Meteorological forcing and observed discharge
  pr <- read_aligned(
    file.path(base, paste0("CAMELS_NZ_", prefix, "_Precipitation"), paste0(file_prefix, "precipitation_station_id_", catchment, ".csv")),
    "precipitation", dates, experiment$timezone)
  
  temp <- read_aligned(
    file.path(base, paste0("CAMELS_NZ_", prefix, "_Temperature"), paste0(file_prefix, "temperature_station_id_", catchment, ".csv")),
    "temperature", dates, experiment$timezone) - 273.15
  
  pet <- read_aligned(
    file.path(base, paste0("CAMELS_NZ_", prefix, "_PET"), paste0(file_prefix, "PET_station_id_", catchment, ".csv")),
    "PET", dates, experiment$timezone)
  
  flow <- read_aligned(
    file.path(base, paste0("CAMELS_NZ_", prefix, "_Streamflow"), paste0(file_prefix, "flow_station_id_", catchment, ".csv")),
    "flow", dates, experiment$timezone)
  
  if (anyNA(pr) || anyNA(temp) || anyNA(pet)) {
    stop("Missing meteorological forcing(s) for basin ", catchment)
  }
  
  # Negative precipitation and PET are not physically meaningful
  if (any(pr < 0)) {
    message("Negative precipitation detected and set to 0 for basin ", catchment)
    pr[pr < 0] <- 0
  }
  
  if (any(pet < 0)) {
    message("Negative PET detected and set to 0 for basin ", catchment)
    pet[pet < 0] <- 0
  }
  
  # Convert observed streamflow from m3/s to catchment-average water depth over one model time step.
  qobs <- flow * time_info$seconds_per_timestep / (area_km2 * 1e6) * 1000
  
  if (any(qobs < 0, na.rm = TRUE)) {
    message("Negative streamflow detected and set to NA for basin ", catchment)
    qobs[qobs < 0] <- NA_real_
  }
  
  # ============================================================================
  # NetCDF time coordinate
  #
  # Current FUSE inputs follow CF conventions and use the midpoint of each
  # forcing interval. Bounds retain the start and end of each interval.
  # ============================================================================
  
  time_origin <- as.POSIXct("1950-01-01 00:00:00", tz = experiment$timezone)
  
  interval_start <- dates
  interval_end <- dates + time_info$seconds_per_timestep
  
  to_nc_time <- function(x) {
    as.numeric(difftime(x, time_origin, units = time_info$time_units))
  }
  
  time_bnds <- cbind(
    to_nc_time(interval_start),
    to_nc_time(interval_end)
  )
  
  time_vals <- 0.5 * (time_bnds[, 1] + time_bnds[, 2])
  time_units <- paste(time_info$time_units, "since", format(time_origin, "%Y-%m-%d %H:%M:%S"))
  
  # ============================================================================
  # Main FUSE forcing file
  # ============================================================================
  
  outdir <- ensure_dir(file.path(paths$forcings, catchment))
  inputname <- file.path(outdir, paste0(catchment, "_input.nc"))
  
  hrudim <- ncdim_def("hru", "", 1L, create_dimvar = FALSE)
  
  timedim <- ncdim_def("time", time_units, time_vals,
                       longname = paste0("midpoint of the ",experiment$timestep ," interval in local standard time"), 
                       create_dimvar = TRUE, unlim = TRUE)
  
  nobsdim <- ncdim_def("nobs", "", 1L, create_dimvar = FALSE)
  
  nbndsdim <- ncdim_def("nbnds", "", 1:2, create_dimvar = FALSE)
  
  Latitude_def <- ncvar_def("latitude", "degrees_north", list(hrudim), missval = NA_real_, longname = "latitude", prec = "double")
  
  Longitude_def <- ncvar_def("longitude", "degrees_east", list(hrudim), missval = NA_real_, longname = "longitude", prec = "double")
  
  CellArea_def <- ncvar_def("cell_area_in_basin", "m2", list(hrudim), longname = "area of spatial element within basin", prec = "float")
  
  BasinArea_def <- ncvar_def("basin_area", "km2", list(), longname = "basin area", prec = "float")
  
  P_def <- ncvar_def("pr", time_info$hydro_units, list(hrudim, timedim), missval = -9999, 
                     longname = paste0(experiment$timestep, " total precipitation"), prec = "double")
  
  T_def <- ncvar_def("temp", "degC", list(hrudim, timedim), missval = -9999, 
                     longname = paste0("mean ",experiment$timestep," temperature"), prec = "double")
  
  PET_def <- ncvar_def("pet", time_info$hydro_units, list(hrudim, timedim), missval = -9999, 
                       longname = paste0("mean ",experiment$timestep," potential evapotranspiration"), prec = "double")
  
  Qobs_def <- ncvar_def("q_obs", time_info$hydro_units, list(nobsdim, timedim), missval = -9999, 
                        longname = paste0("observed ",experiment$timestep," discharge"), prec = "double")
  
  TimeBounds_def <- ncvar_def("time_bnds", time_units, list(nbndsdim, timedim), 
                              longname = paste0(experiment$timestep, " interval bounds in local standard time"), prec = "double")
  
  nc <- nc_create(inputname, list(Latitude_def, Longitude_def, CellArea_def, BasinArea_def,
                                  P_def, T_def, PET_def, Qobs_def, TimeBounds_def), force_v4 = TRUE)
  
  ncvar_put(nc, Latitude_def, lat)
  ncvar_put(nc, Longitude_def, lon)
  
  ncvar_put(nc, CellArea_def, area_km2 * 1e6)
  ncvar_put(nc, BasinArea_def, area_km2)
  
  ncvar_put(nc, P_def, array(pr, c(1, length(pr))))
  ncvar_put(nc, T_def, array(temp, c(1, length(temp))))
  ncvar_put(nc, PET_def, array(pet, c(1, length(pet))))
  ncvar_put(nc, Qobs_def, array(qobs, c(1, length(qobs))))
  
  ncvar_put(nc, TimeBounds_def, t(time_bnds))
  
  # CF metadata used by the current FUSE forcing convention.
  ncatt_put(nc, "latitude", "standard_name", "latitude")
  ncatt_put(nc, "latitude", "cell_methods", "time: mean")
  
  ncatt_put(nc, "longitude", "standard_name", "longitude")
  ncatt_put(nc, "longitude", "cell_methods", "time: mean")
  
  ncatt_put(nc, "time", "axis", "T")
  ncatt_put(nc, "time", "standard_name", "time")
  ncatt_put(nc, "time", "calendar", "proleptic_gregorian")
  ncatt_put(nc, "time", "bounds", "time_bnds")
  ncatt_put(nc, "time", "time_basis", "local standard time")
  
  ncatt_put(nc, "time_bnds", "calendar", "proleptic_gregorian")
  ncatt_put(nc, "time_bnds", "time_basis", "local standard time")
  
  ncatt_put(nc, 0, "Conventions", "CF-1.10")
  ncatt_put(nc, 0, "title", "FUSE meteorological forcing and streamflow observations")
  ncatt_put(nc, 0, "station", catchment)
  ncatt_put(nc, 0, "source", "CAMELS-NZ")
  ncatt_put(nc, 0, "institution", "University of Calgary")
  ncatt_put(nc, 0, "workflow", paste0("CAMELS-NZ lumped ", experiment$timestep, " LSE"))
  
  nc_close(nc)
  
  
  # ============================================================================
  # Elevation-band file
  #
  # The present workflow is lumped, so the full catchment is represented by one
  # elevation band with unit area and precipitation fractions.
  # ============================================================================
  
  elevname <- file.path(outdir, paste0(catchment, "_elev_bands.nc"))
  
  latdim <- ncdim_def("latitude", "degreesN", lat, longname = "latitude")
  londim <- ncdim_def("longitude", "degreesE", lon, longname = "longitude")
  elevdim <- ncdim_def("elevation_band", "-", 1L, longname = "elevation_band")
  
  AreaFrac_def <- ncvar_def("area_frac", "-", list(latdim, londim, elevdim), longname = "Fraction of the catchment covered by each elevation band", prec = "double")
  MeanElev_def <- ncvar_def("mean_elev", "m asl", list(latdim, londim, elevdim), longname = "Mean elevation of each elevation band", prec = "double")
  PrecFrac_def <- ncvar_def("prec_frac", "-", list(latdim, londim, elevdim), longname = "Fraction of catchment precipitation that falls on each elevation band", prec = "double")
  
  nc <- nc_create(elevname, list(AreaFrac_def, MeanElev_def, PrecFrac_def), force_v4 = TRUE)
  
  ncvar_put(nc, AreaFrac_def, array(1, dim = c(1, 1, 1)))
  ncvar_put(nc, MeanElev_def, array(elevation, dim = c(1, 1, 1)))
  ncvar_put(nc, PrecFrac_def, array(1, dim = c(1, 1, 1)))
  
  ncatt_put(nc, 0, "institution", "University of Calgary")
  ncatt_put(nc, 0, "workflow", paste0("CAMELS-NZ lumped ", experiment$timestep, " LSE"))
  
  nc_close(nc)
}