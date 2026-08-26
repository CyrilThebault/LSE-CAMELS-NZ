#!/usr/bin/env Rscript

# ==============================================================================
# Create FUSE metadata used throughout the emulator workflow
#
# The object created here describes the FUSE parameter space and identifies
# which parameters are active for each structural configuration. The decision
# table is also checked against the corresponding FUSE decision files.
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 1L) {
  stop("Usage: Rscript 03_create_FUSE_metadata.R <dirMain>")
}

dirMain <- normalizePath(args[1], mustWork = TRUE)

source(file.path(dirMain, "scripts/functions/common.R"))

paths <- project_paths(dirMain)

dirSettings <- paths$settings
dirDecisions <- paths$decisions
dirUseful <- paths$useful

ensure_dir(dirUseful)

fileConstraints <- file.path(dirSettings, "fuse_zConstraints_snow.txt")
fileNumerix <- file.path(dirSettings, "fuse_zNumerix.txt")
fileDecisionList <- file.path(dirSettings, "list_decision_78.txt")
fileOutput <- file.path(dirUseful, "fuse_settings_files.RData")


# ==============================================================================
# Functions
# ==============================================================================

# Extract the parameter names from the FUSE constraint file.
get_parameter_names <- function(zConstraints) {
  
  parameterRows <- grep("^[[:space:]]*[FT][[:space:]]", zConstraints)
  parameterLines <- zConstraints[parameterRows]
  
  parameterTokens <- strsplit(
    trimws(sub("!.*$", "", parameterLines)),
    "[[:space:]]+"
  )
  
  ParameterNames <- vapply(parameterTokens, function(x) {
    
    if (length(x) < 14) {
      stop("Cannot identify parameter name in line:\n", paste(x, collapse = " "))
    }
    
    x[14]
    
  }, character(1))
  
  ParameterNames
}


# Parse the FUSE constraint file while retaining the fields required later when
# generating parameter files for individual model configurations.
parse_constraints <- function(zConstraints) {
  
  parameterRows <- grep("^[[:space:]]*[FT][[:space:]]", zConstraints)
  parameterLines <- zConstraints[parameterRows]
  
  parameterTokens <- strsplit(
    trimws(sub("!.*$", "", parameterLines)),
    "[[:space:]]+"
  )
  
  nFields <- lengths(parameterTokens)
  
  if (any(nFields < 14)) {
    bad <- which(nFields < 14)
    stop("Problem parsing constraint line(s): ", paste(parameterRows[bad], collapse = ", "))
  }
  
  params <- data.frame(
    row = as.numeric(parameterRows),
    default = vapply(parameterTokens, function(x) as.numeric(x[3]), numeric(1)),
    min = vapply(parameterTokens, function(x) as.numeric(x[4]), numeric(1)),
    max = vapply(parameterTokens, function(x) as.numeric(x[5]), numeric(1)),
    text.1 = vapply(parameterTokens, function(x) x[1], character(1)),
    text.2 = vapply(parameterTokens, function(x) paste0(" ", x[2], " "), character(1)),
    text.b = sub(
      "^[[:space:]]*[FT][[:space:]]+[+-]?[0-9]+[[:space:]]+[-+0-9.eE]+",
      "",
      parameterLines
    ),
    stringsAsFactors = FALSE
  )
  
  rownames(params) <- NULL
  
  params
}


# Read the ten structural choices defining one FUSE configuration.
read_decision_file <- function(file) {
  
  if (!file.exists(file)) {
    stop("Decision file does not exist: ", file)
  }
  
  x <- readLines(file, warn = FALSE)
  
  decisionNames <- c(
    "RFERR", "ARCH1", "ARCH2", "QSURF", "QPERC",
    "ESOIL", "QINTF", "Q_TDH", "SNOWM", "INTRC"
  )
  
  decisions <- setNames(rep(NA_character_, length(decisionNames)), decisionNames)
  
  for (line in x) {
    
    # Remove FUSE comments before parsing the structural choice.
    lineClean <- trimws(sub("!.*$", "", line))
    
    if (!nzchar(lineClean)) {
      next
    }
    
    tokens <- strsplit(lineClean, "[[:space:]]+")[[1]]
    
    if (length(tokens) < 2) {
      next
    }
    
    decisionName <- tokens[2]
    
    if (decisionName %in% decisionNames) {
      decisions[decisionName] <- tokens[1]
    }
    
    if (all(!is.na(decisions))) {
      break
    }
  }
  
  if (any(is.na(decisions))) {
    stop(
      "Could not read all model decisions from:\n", file,
      "\nMissing: ", paste(names(decisions)[is.na(decisions)], collapse = ", ")
    )
  }
  
  decisions
}


# Convert the structural choices into a mask identifying the parameters that are
# active for a given FUSE configuration.
get_parameter_mask <- function(decision, ParameterNames, fit) {
  
  mask <- setNames(rep(FALSE, length(ParameterNames)), ParameterNames)
  
  add <- function(x) {
    x <- intersect(x, names(mask))
    mask[x] <<- TRUE
  }
  
  # Rainfall error
  if (decision[["RFERR"]] == "additive_e") {
    add("RFERR_ADD")
  }
  
  if (decision[["RFERR"]] == "multiplc_e") {
    add("RFERR_MLT")
  }
  
  # Upper-layer architecture
  add(c("MAXWATR_1", "FRACTEN"))
  
  if (decision[["ARCH1"]] == "tension2_1") {
    add("FRCHZNE")
  }
  
  # Lower-layer architecture and baseflow
  add(c("MAXWATR_2", "LOGLAMB", "TISHAPE", "QB_POWR"))
  
  if (decision[["ARCH2"]] == "fixedsiz_2") {
    add("BASERTE")
  }
  
  if (decision[["ARCH2"]] == "tens2pll_2") {
    add(c("PERCFRAC", "FPRIMQB", "QBRATE_2A", "QBRATE_2B"))
  }
  
  if (decision[["ARCH2"]] == "unlimfrc_2") {
    add("QB_PRMS")
  }
  
  if (decision[["ARCH2"]] == "unlimpow_2") {
    add("BASERTE")
  }
  
  # Surface runoff
  if (decision[["QSURF"]] == "arno_x_vic") {
    add("AXV_BEXP")
  }
  
  if (decision[["QSURF"]] == "prms_varnt") {
    add("SAREAMAX")
  }
  
  # Percolation
  if (decision[["QPERC"]] %in% c("perc_f2sat", "perc_w2sat")) {
    add(c("PERCRTE", "PERCEXP"))
  }
  
  if (decision[["QPERC"]] == "perc_lower") {
    add(c("SACPMLT", "SACPEXP"))
  }
  
  # Evaporation
  if (decision[["ESOIL"]] == "rootweight") {
    add("RTFRAC1")
  }
  
  # Interflow
  if (decision[["QINTF"]] == "intflwsome") {
    add("IFLWRTE")
  }
  
  # Routing
  if (decision[["Q_TDH"]] == "rout_gamma") {
    add("TIMEDELAY")
  }
  
  # Snow model
  if (decision[["SNOWM"]] == "temp_index") {
    add(c("MBASE", "MFMAX", "MFMIN", "PXTEMP", "OPG", "LAPSE"))
  }
  
  # Interception
  if (decision[["INTRC"]] == "gr5h_intrc") {
    add("REFSINT_0")
  }
  
  if (!decision[["INTRC"]] %in% c("no_intrcep", "gr5h_intrc")) {
    stop("Unknown interception option: ", decision[["INTRC"]])
  }
  
  # Parameters marked F in the constraint file are fixed and must therefore not
  # be included in the calibration space.
  mask <- mask & fit
  
  as.numeric(mask)
}


# ==============================================================================
# Read FUSE settings
# ==============================================================================

zConstraints <- readLines(fileConstraints, warn = FALSE)
zNumerix <- readLines(fileNumerix, warn = FALSE)

# ==============================================================================
# Parameter information
# ==============================================================================

params <- parse_constraints(zConstraints)
ParameterNames <- get_parameter_names(zConstraints)

if (nrow(params) != length(ParameterNames)) {
  stop("params and parameter names have different lengths.")
}

message("Object contains ", length(ParameterNames), " parameters.")

if (!"REFSINT_0" %in% ParameterNames) {
  stop("REFSINT_0 was not found in the new constraints file.")
}

# Parameters marked T in the FUSE constraint file are available for calibration.
fit <- params$text.1 == "T"
names(fit) <- ParameterNames


# ==============================================================================
# Structural configurations
# ==============================================================================

decisionTable <- read.table(fileDecisionList, header = TRUE, sep = ";")

if (!"ID" %in% names(decisionTable)) {
  stop("Column 'ID' does not exist in ", basename(fileDecisionList))
}

decisionTable$ID <- as.character(decisionTable$ID)
decisions <- sort(unique(decisionTable$ID))

message("Number of FUSE configurations: ", length(decisions))

decisionColumns <- c(
  "RFERR", "ARCH1", "ARCH2", "QSURF", "QPERC",
  "ESOIL", "QINTF", "Q_TDH", "SNOWM", "INTRC"
)

missingDecisionColumns <- setdiff(decisionColumns, names(decisionTable))

if (length(missingDecisionColumns) > 0L) {
  stop("Missing columns in decision list: ", paste(missingDecisionColumns, collapse = ", "))
}


# ==============================================================================
# Link each FUSE configuration to its active parameters
# ==============================================================================

configs_to_params <- setNames(
  vector("list", length(decisions)),
  paste0("zDecision_", decisions)
)

for (i in seq_along(decisions)) {
  
  ID <- decisions[i]
  
  # Read the structural choices listed for this configuration.
  j <- which(decisionTable$ID == ID)
  
  if (length(j) != 1L) {
    stop("Expected exactly one row for decision ID ", ID)
  }
  
  decision <- unlist(
    decisionTable[j, decisionColumns, drop = FALSE],
    use.names = TRUE
  )
  
  decision <- as.character(decision)
  names(decision) <- decisionColumns
  
  # The individual FUSE decision file must exist and describe the same model
  # structure as the central decision table.
  fileName <- paste0("fuse_zDecisions_", ID, ".txt")
  fileDecision <- file.path(dirDecisions, fileName)
  
  if (!file.exists(fileDecision)) {
    stop("Decision file does not exist:\n", fileDecision)
  }
  
  decisionFromFile <- read_decision_file(fileDecision)
  
  differences <- decisionColumns[
    decision[decisionColumns] != decisionFromFile[decisionColumns]
  ]
  
  if (length(differences) > 0L) {
    stop(
      "\nMismatch for zDecision ", ID,
      "\nbetween list_decision_78.txt and ", fileName,
      "\nComponent(s): ", paste(differences, collapse = ", ")
    )
  }
  
  parameterMask <- get_parameter_mask(
    decision = decision,
    ParameterNames = ParameterNames,
    fit = fit
  )
  
  configs_to_params[[paste0("zDecision_", ID)]] <- list(
    zDecision = ID,
    params = parameterMask,
    fileName = fileName
  )
  
  message("----- ", i, "/", length(decisions), " | zDecision_", ID, " ready!")
}


# ==============================================================================
# Create final metadata object
# ==============================================================================

fuse_settings_files <- list(
  zConstraints = zConstraints,
  zNumerix = zNumerix,
  params = params,
  decisions = decisions,
  configs_to_params = configs_to_params
)


# ==============================================================================
# Final consistency checks
# ==============================================================================

nParameters <- nrow(fuse_settings_files$params)

maskLengths <- vapply(
  fuse_settings_files$configs_to_params,
  function(x) length(x$params),
  integer(1)
)

if (any(maskLengths != nParameters)) {
  stop("Some parameter masks do not have ", nParameters, " elements.")
}

if (length(fuse_settings_files$decisions) != length(fuse_settings_files$configs_to_params)) {
  stop("decisions and configs_to_params have different lengths.")
}

expectedConfigNames <- paste0("zDecision_", fuse_settings_files$decisions)

if (!identical(names(fuse_settings_files$configs_to_params), expectedConfigNames)) {
  stop("Names of configs_to_params are not consistent with decisions.")
}


# ==============================================================================
# Display and save
# ==============================================================================

cat("\n")
cat("============================================================\n")
cat("fuse_settings_files successfully created\n")
cat("============================================================\n")
cat("Parameters     : ", nParameters, "\n", sep = "")
cat("Configurations : ", length(fuse_settings_files$decisions), "\n", sep = "")

str(fuse_settings_files, max.level = 2)

# Display configuration 126 as a simple diagnostic when it is available.
if ("zDecision_126" %in% names(fuse_settings_files$configs_to_params)) {
  
  cat("\nConfiguration 126:\n")
  print(fuse_settings_files$configs_to_params$zDecision_126)
  
  cat("\nParameter mask for configuration 126:\n")
  print(
    data.frame(
      parameter = ParameterNames,
      active = fuse_settings_files$configs_to_params$zDecision_126$params
    )
  )
}

save(fuse_settings_files, file = fileOutput)

cat("\n")
message("Saved to: ", fileOutput)