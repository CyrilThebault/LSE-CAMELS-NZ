# ==============================================================================
# Read basin information
#
# Basin files may either contain a single column of IDs with no header, or a
# table with a header containing a column named ID.
# ==============================================================================

read_basin_table <- function(file) {
  
  if (!file.exists(file)) {
    stop("Basin file does not exist: ", file)
  }
  
  lines <- readLines(file, warn = FALSE)
  lines <- lines[nzchar(trimws(lines))]
  
  if (!length(lines)) {
    stop("Basin file is empty: ", file)
  }
  
  first <- trimws(lines[1])
  
  # Detect whether the first line contains an ID column header.
  has_header <- grepl("(^|[|,;[:space:]])ID($|[|,;[:space:]])", first)
  
  if (has_header) {
    
    sep <- if (grepl("\\|", first)) {
      "|"
    } else if (grepl(";", first)) {
      ";"
    } else if (grepl(",", first)) {
      ","
    } else {
      ""
    }
    
    x <- read.table(
      file,
      header = TRUE,
      sep = sep,
      stringsAsFactors = FALSE,
      check.names = FALSE,
      comment.char = "",
      quote = '"'
    )
    
    if (!"ID" %in% names(x)) {
      stop("Header detected but column 'ID' is absent: ", file)
    }
    
  } else {
    
    ids <- scan(file, what = character(), quiet = TRUE)
    x <- data.frame(ID = ids, stringsAsFactors = FALSE)
  }
  
  x$ID <- as.character(x$ID)
  
  if (anyNA(x$ID) || any(!nzchar(x$ID))) {
    stop("Missing/empty basin ID in ", file)
  }
  
  if (anyDuplicated(x$ID)) {
    stop("Duplicated basin IDs in ", file)
  }
  
  x
}


# Return only the basin IDs when no additional basin information is required.
read_basin_ids <- function(file) {
  read_basin_table(file)$ID
}


# Write basin IDs in the simple one-ID-per-line format used by experiment folds.
write_basin_ids <- function(ids, file) {
  
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  
  writeLines(as.character(ids), file)
}