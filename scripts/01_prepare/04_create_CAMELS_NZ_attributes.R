#!/usr/bin/env Rscript

# ==============================================================================
# Create the CAMELS-NZ static attribute table used by the emulator
#
# The five CAMELS-NZ attribute tables are aligned by Station_ID and merged into
# a single basin-level data frame. Identifier and location fields are kept only
# once, while all remaining static attributes are retained for later selection.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 1L) {
  stop("Usage: Rscript 04_create_CAMELS_NZ_attributes.R <dirMain>")
}

dirMain <- normalizePath(args[1], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))

experiment <- load_workflow_config(dirMain)
paths <- project_paths(dirMain, experiment)

dir_attributes <- file.path(experiment$paths$camels_nz, "CAMELS_NZ_Catchment_Atrributes")


# ==============================================================================
# Read CAMELS-NZ attribute tables
# ==============================================================================

files <- c(
  catchment = "1.CAMELS_NZ_Catchment_information.csv",
  climate = "2.CAMELS_NZ_Climatic_attribute.csv",
  landcover = "3.CAMELS_NZ_Landcover_attribute.csv",
  geology = "4.CAMELS_NZ_Geology.csv",
  anthropogenic = "5.CAMELS_NZ_Anthropogenic_attribute.csv"
)

tabs <- lapply(files, function(f) {
  read.csv(file.path(dir_attributes, f), fileEncoding = "UTF-8-BOM",
           stringsAsFactors = FALSE, check.names = FALSE)
})


# ==============================================================================
# Check basin identifiers
# ==============================================================================

for (nm in names(tabs)) {
  
  if (!"Station_ID" %in% names(tabs[[nm]])) {
    stop("Station_ID missing from ", nm)
  }
  
  if (anyDuplicated(tabs[[nm]]$Station_ID)) {
    stop("Duplicated Station_ID in ", nm)
  }
}

master <- tabs$catchment$Station_ID

# Every attribute table must contain exactly the same set of CAMELS-NZ basins.
for (nm in names(tabs)[-1]) {
  
  if (!setequal(master, tabs[[nm]]$Station_ID)) {
    stop("Station_ID mismatch in ", nm)
  }
  
  tabs[[nm]] <- tabs[[nm]][match(master, tabs[[nm]]$Station_ID), , drop = FALSE]
}


# ==============================================================================
# Common basin information
# ==============================================================================

id_cols <- c(
  "Station_ID", "RID",
  "Station Name", "StationName",
  "Latitude (WGS 84)", "Longitude(WGS 84)",
  "latitude", "longitude"
)

name_col <- intersect(c("Station Name", "StationName"), names(tabs$catchment))[1]
lat_col <- intersect(c("Latitude (WGS 84)", "Latitude..WGS.84."), names(tabs$catchment))[1]
lon_col <- intersect(c("Longitude(WGS 84)", "Longitude.WGS.84."), names(tabs$catchment))[1]

if (anyNA(c(name_col, lat_col, lon_col))) {
  stop("Could not identify basin name, latitude or longitude columns.")
}

attributes <- data.frame(
  ID = as.character(master),
  name = tabs$catchment[[name_col]],
  lat = tabs$catchment[[lat_col]],
  lon = tabs$catchment[[lon_col]],
  country = "NZ",
  stringsAsFactors = FALSE
)


# ==============================================================================
# Merge static attributes
#
# Station identifiers and location fields are excluded here because they are
# already stored in the common basin-information columns above.
# ==============================================================================

for (nm in names(tabs)) {
  
  keep <- setdiff(names(tabs[[nm]]), id_cols)
  
  attributes <- cbind(attributes, tabs[[nm]][, keep, drop = FALSE])
}


# ==============================================================================
# Final checks and save
# ==============================================================================

if (anyDuplicated(attributes$ID)) {
  stop("Duplicated IDs in final attributes")
}

ensure_dir(paths$useful)

save(attributes, file = file.path(paths$useful, "attributes.RData"))

message("Saved attributes: ", nrow(attributes), " basins x ", ncol(attributes), " columns")