# ==============================================================================
# Read hourly observed discharge directly from CAMELS-NZ
#
# Reproduce the Qobs preparation in 01_prepare_CAMELS_NZ.R without requiring
# hourly FUSE forcing files. Flood analyses always use hourly observations,
# independently of the experiment timestep.
# ==============================================================================

read_camels_nz_hourly_qobs <- function(ID, experiment, metadata) {

  ID <- as.character(ID)

  row <- which(as.character(metadata$Station_ID) == ID)

  if (length(row) != 1L) {
    stop("Expected one metadata row for ", ID)
  }

  area_km2 <- as.numeric(metadata[row, "uparea"])

  if (!is.finite(area_km2) || area_km2 <= 0) {
    stop("Invalid catchment area for basin ", ID)
  }

  start <- experiment$simulation_start
  end <- experiment$simulation_end

  if (experiment$timestep == "daily") {
    end <- end + 23 * 3600
  } else if (experiment$timestep != "hourly") {
    stop("Unknown experiment timestep: ", experiment$timestep)
  }

  dates <- seq.POSIXt(from = start, to = end, by = "hours")

  file <- file.path(
    experiment$paths$camels_nz,
    "CAMELS_NZ_hourly_Streamflow",
    paste0("flow_station_id_", ID, ".csv")
  )

  if (!file.exists(file)) {
    stop("Missing CAMELS-NZ hourly streamflow file: ", file)
  }

  x <- read.csv(file, stringsAsFactors = FALSE, check.names = FALSE)

  if (!all(c("time", "flow") %in% names(x))) {
    stop("Missing time/flow columns in ", file)
  }

  x$time <- as.POSIXct(x$time, tz = experiment$timezone)

  flow <- x$flow[match(dates, x$time)]

  q <- flow * 3600 / (area_km2 * 1e6) * 1000

  q[q < 0] <- NA_real_

  list(
    q = q,
    time = dates + 1800
  )
}
