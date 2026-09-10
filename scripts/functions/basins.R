# Return only the basin IDs when no additional basin information is required.
read_basin_ids <- function(file) {
  
  if (!file.exists(file)) {
    stop("Missing basin file: ", file)
  }
  
  basins <- trimws(readLines(file, warn = FALSE))
  
  if (!length(basins)) {
    stop("Empty basin file: ", file)
  }
  
  if (any(!nzchar(basins))) {
    stop("Empty line(s) in basin file: ", file)
  }
  
  if (any(grepl("\\s", basins))) {
    stop("Each line of the basin file must contain exactly one basin ID: ", file)
  }
  
  if (anyDuplicated(basins)) {
    stop("Duplicate basin ID(s) in: ", file)
  }
  
  basins
}


# Write basin IDs in the simple one-ID-per-line format used by experiment folds.
write_basin_ids <- function(ids, file) {
  
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  
  writeLines(as.character(ids), file)
}