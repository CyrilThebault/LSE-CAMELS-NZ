#!/usr/bin/env Rscript

# ==============================================================================
# LSE-CAMELS-NZ
# 06_analysis / 03_compare_paired_daily.R
#
# Compare daily FUSE simulations with hourly FUSE simulations aggregated
# to daily resolution, using identical observed days.
#
# Usage:
#   Rscript 03_compare_paired_daily.R DIRMAIN EVALUATIONS_RDS OUTDIR
#     [--check] [--ncores=N]
#
# Optional multicore execution on macOS and Linux uses parallel::mclapply().
# Scientific processing and the output RDS schema are unchanged.
#
# Principles:
#   - Discover complete daily/hourly pairs from the consolidated evaluation RDS
#   - Use the configurations referenced by evaluation metadata
#   - Reuse archived continuous metrics on identical valid days
#   - Recompute metrics only when strict pairing changes coverage
#   - Use identical calendar days and original daily Qobs
#   - Reuse existing hydrological evaluation functions
#   - Never recalculate flood metrics
#   - Support incomplete campaigns
#   - Never modify simulation or evaluation results
#   - Never overwrite existing analysis outputs
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- paste(
  "Usage: Rscript 03_compare_paired_daily.R",
  "DIRMAIN EVALUATIONS_RDS OUTDIR [--check] [--ncores=N]"
)

if (length(args) < 3L) {
  stop(usage, call. = FALSE)
}

cli_options <- if (length(args) > 3L) args[-seq_len(3L)] else character()
core_options <- grep("^--ncores=", cli_options, value = TRUE)

if (
  any(!cli_options %in% c("--check", core_options)) ||
  sum(cli_options == "--check") > 1L ||
  length(core_options) > 1L ||
  (length(core_options) == 1L &&
    !grepl("^--ncores=[1-9][0-9]*$", core_options))
) {
  stop(usage, call. = FALSE)
}

ncores <- if (length(core_options) == 1L) {
  suppressWarnings(as.integer(sub("^--ncores=", "", core_options)))
} else {
  1L
}

if (is.na(ncores) || ncores < 1L ||
    (ncores > 1L && .Platform$OS.type != "unix")) {
  stop("Invalid --ncores: expected a positive integer on macOS/Linux", call. = FALSE)
}

dirMain <- normalizePath(args[[1L]], mustWork = TRUE)
input_file <- normalizePath(args[[2L]], mustWork = TRUE)
outdir <- path.expand(args[[3L]])
check_only <- "--check" %in% cli_options

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/fuse.R"))
source(file.path(dirMain, "scripts/functions/evaluation_series.R"))

assert <- function(condition, message) {
  if (!isTRUE(condition)) {
    stop(message, call. = FALSE)
  }
}

makekey <- function(x, columns) {
  do.call(paste, c(unname(x[columns]), sep = "|"))
}

# ==============================================================================
# 1. Load consolidated evaluation inventory
# ==============================================================================

cat("\n===== INPUT =====\n")
cat("Repository:", dirMain, "\n")
cat("Evaluations:", input_file, "\n")
cat("Mode:", if (check_only) "CHECK" else "COMPARE", "\n")
cat("Requested CPU cores:", ncores, "\n")

evaluations <- readRDS(input_file)

assert(
  is.list(evaluations) &&
    identical(
      evaluations$schema_version,
      "lse_evaluations_consolidated_v1"
    ),
  "Unsupported evaluation RDS schema"
)

manifest <- evaluations$manifest

assert(
  is.data.frame(manifest),
  "Invalid evaluation manifest"
)

keycols <- c("strategy", "unit", "basin", "method")

required_manifest <- c(
  "resolution",
  keycols,
  "status",
  "metadata_file"
)

assert(
  all(required_manifest %in% names(manifest)),
  "Incomplete evaluation manifest"
)

assert(
  !anyNA(manifest[, c("resolution", keycols, "status")]),
  "Missing evaluation identity"
)

assert(
  !anyDuplicated(
    makekey(manifest, c("resolution", keycols))
  ),
  "Duplicate evaluation identities"
)

# Include complete emulator and local-calibration evaluations.

complete <- manifest[
  manifest$status == "complete",
  ,
  drop = FALSE
]

daily_manifest <- complete[
  complete$resolution == "daily",
  ,
  drop = FALSE
]

hourly_manifest <- complete[
  complete$resolution == "hourly",
  ,
  drop = FALSE
]

daily_keys <- makekey(daily_manifest, keycols)
hourly_keys <- makekey(hourly_manifest, keycols)

matched_keys <- sort(intersect(daily_keys, hourly_keys))

cat("\n===== AVAILABLE SIMULATIONS =====\n")
cat("Complete daily:", nrow(daily_manifest), "\n")
cat("Complete hourly:", nrow(hourly_manifest), "\n")
cat("Matched daily/hourly:", length(matched_keys), "\n")
cat("Daily without hourly:", length(setdiff(daily_keys, hourly_keys)), "\n")
cat("Hourly without daily:", length(setdiff(hourly_keys, daily_keys)), "\n")

assert(
  length(matched_keys) > 0L,
  "No complete daily/hourly emulator pairs available"
)

# ==============================================================================
# 2. Validate simulation metadata
# ==============================================================================

validate_pair <- function(md, mh, row) {

  assert(
    identical(md$timestep, "daily") &&
      identical(mh$timestep, "hourly"),
    "Invalid evaluation timestep"
  )

  assert(
    identical(md$method_type, mh$method_type) &&
      md$method_type %in% c("emulator", "localcalib"),
    "Incompatible evaluation method types"
  )

  for (field in c(
    "basinID",
    "zDecision",
    "method",
    "modelStep",
    "phase",
    "metric_period_rule"
  )) {

    assert(
      identical(
        as.character(md[[field]]),
        as.character(mh[[field]])
      ),
      paste("Daily/hourly metadata mismatch:", field)
    )
  }

  for (field in c("basinID", "method")) {

    expected <- if (field == "basinID") {
      row$basin[[1L]]
    } else {
      row$method[[1L]]
    }

    assert(
      identical(as.character(md[[field]]), as.character(expected)),
      paste("Manifest/metadata mismatch:", field)
    )
  }

  if (identical(md$method_type, "emulator")) {

    assert(
      identical(md$phase, "test") &&
        !is.null(md$modelStep),
      "Invalid emulator evaluation metadata"
    )

  } else {

    assert(
      identical(md$method, "sce") &&
        identical(row$strategy[[1L]], "localcalib") &&
        identical(row$unit[[1L]], "all_basins") &&
        is.null(md$modelStep) &&
        is.null(mh$modelStep) &&
        is.null(md$phase) &&
        is.null(mh$phase),
      "Invalid local-calibration metadata"
    )
  }

  assert(
    identical(
      md$metric_period_rule,
      "complete_calendar_days_v1"
    ),
    "Unsupported evaluation period convention"
  )

  for (m in list(md, mh)) {

    experiment_path <- gsub(
      "\\\\", "/", as.character(m$experiment_dir)
    )

    assert(
      identical(basename(experiment_path), row$unit[[1L]]) &&
        identical(
          basename(dirname(experiment_path)),
          row$strategy[[1L]]
        ),
      "Spatial experiment metadata mismatch"
    )
  }

  assert(
    identical(
      names(md$metric_periods),
      names(mh$metric_periods)
    ),
    "Evaluation periods differ"
  )

  for (period in names(md$metric_periods)) {
    for (bound in c("ti", "tf")) {

      assert(
        identical(
          as.numeric(md$metric_periods[[period]][[bound]]),
          as.numeric(mh$metric_periods[[period]][[bound]])
        ),
        paste("Effective period boundary mismatch:", period, bound)
      )
    }
  }

  invisible(TRUE)
}

# Archived paths may refer to another computer.
# Only the exact path relative to experiments/ may be rebased.
# Configuration paths are NEVER silently rebased.

resolve_simulation_file <- function(path) {

  assert(
    length(path) == 1L &&
      !is.na(path) &&
      nzchar(path),
    "Invalid archived simulation path"
  )

  if (file.exists(path)) {
    return(normalizePath(path, mustWork = TRUE))
  }

  normalized <- gsub("\\\\", "/", path)
  marker <- "/experiments/"

  position <- regexpr(
    marker,
    normalized,
    fixed = TRUE
  )[[1L]]

  assert(
    position > 0L,
    paste("Cannot resolve archived simulation:", path)
  )

  relative <- substring(normalized, position + 1L)

  candidate <- file.path(dirMain, relative)

  assert(
    file.exists(candidate),
    paste(
      "Archived simulation is unavailable:",
      path,
      "\nLocal candidate:",
      candidate
    )
  )

  cat("Rebased simulation:", candidate, "\n")

  normalizePath(candidate, mustWork = TRUE)
}

# ==============================================================================
# 3. Archived metric reproduction
# ==============================================================================

read_archived_metrics <- function(table, row, resolution) {

  required <- c(
    "resolution",
    keycols,
    "period",
    "NSE",
    "KGE.2009"
  )

  assert(
    is.data.frame(table) &&
      all(required %in% names(table)),
    "Invalid consolidated continuous metric table"
  )

  selected <- table[
    table$resolution == resolution &
      table$strategy == row$strategy[[1L]] &
      table$unit == row$unit[[1L]] &
      as.character(table$basin) == as.character(row$basin[[1L]]) &
      table$method == row$method[[1L]],
    ,
    drop = FALSE
  ]

  assert(
    nrow(selected) == 2L &&
      setequal(
        selected$period,
        c("calibration", "evaluation")
      ),
    paste("Incomplete archived continuous metrics:", resolution)
  )

  selected
}

calculate_metrics <- function(series, basin, periods) {

  calculated <- compute_flow_metrics(
    qsim = series[, c("time", "qSim")],
    qobs = series[, c("time", "qObs")],
    basinID = basin,
    periods = periods
  )

  assert(
    !is.null(calculated) &&
      nrow(calculated) == length(periods),
    paste("Cannot calculate continuous metrics:", basin)
  )

  calculated
}

# ==============================================================================
# 4. Process all matched simulations
# ==============================================================================

# Keep the exact same per-pair scientific calculations in a pure worker.
# lapply() preserves the existing serial behavior; mclapply() preserves
# the same input order when multiple CPU cores are requested.
process_pair <- function(i) {

  key <- matched_keys[[i]]

  row_d <- daily_manifest[
    daily_keys == key,
    ,
    drop = FALSE
  ]

  row_h <- hourly_manifest[
    hourly_keys == key,
    ,
    drop = FALSE
  ]

  assert(
    nrow(row_d) == 1L && nrow(row_h) == 1L,
    paste("Ambiguous simulation pair:", key)
  )

  cat(
    "\n===== PAIR", i, "/", length(matched_keys), "=====\n"
  )
  cat(key, "\n")

  assert(
    file.exists(row_d$metadata_file[[1L]]) &&
      file.exists(row_h$metadata_file[[1L]]),
    paste("Missing evaluation metadata:", key)
  )

  md <- readRDS(row_d$metadata_file[[1L]])
  mh <- readRDS(row_h$metadata_file[[1L]])

  validate_pair(md, mh, row_d)

  basin <- as.character(md$basinID)
  periods <- md$metric_periods

  assert(
    all(c("calibration", "evaluation") %in% names(periods)),
    paste("Missing metric periods:", key)
  )

  # Configurations are read from the paths actually archived
  # in metadata.rds. No implicit configuration substitution.

  # The metadata must reference the same existing canonical
  # configuration. Never rebase or substitute configuration paths.

  assert(
    is.character(md$config_file) &&
      length(md$config_file) == 1L &&
      !is.na(md$config_file) &&
      nzchar(md$config_file) &&
      identical(md$config_file, mh$config_file),
    paste("Daily/hourly configuration reference mismatch:", key)
  )

  assert(
    file.exists(md$config_file),
    paste("Metadata configuration file missing:", md$config_file)
  )

  canonical_config <- normalizePath(
    file.path(dirMain, "config", "experiment.R"),
    mustWork = TRUE
  )

  recorded_config <- normalizePath(
    md$config_file,
    mustWork = TRUE
  )

  assert(
    identical(recorded_config, canonical_config),
    paste("Metadata does not reference canonical configuration:", key)
  )

  cfg_d <- load_workflow_config(
    md$config_file,
    timestep = "daily"
  )

  cfg_h <- load_workflow_config(
    mh$config_file,
    timestep = "hourly"
  )

  cat("PASS: identical canonical configuration reference\n")

  assert(
    identical(cfg_d$timestep, "daily") &&
      identical(cfg_h$timestep, "hourly") &&
      identical(cfg_d$timezone, cfg_h$timezone),
    paste("Configuration timestep/timezone mismatch:", key)
  )

  for (cfg in list(cfg_d, cfg_h)) {

    assert(
      identical(
        as.character(cfg$zDecision),
        as.character(md$zDecision)
      ),
      paste("Configuration zDecision mismatch:", key)
    )

    if (identical(md$method_type, "emulator")) {

      assert(
        identical(
          as.integer(cfg$nRefinementSteps),
          as.integer(md$modelStep)
        ) &&
          md$method %in% cfg$emulators,
        paste("Emulator configuration mismatch:", key)
      )
    }
  }

  for (field in c(
    "calibration_start",
    "calibration_end",
    "evaluation_start",
    "evaluation_end"
  )) {

    if (
      !is.null(md[[field]]) &&
      !is.null(cfg_d[[field]])
    ) {

      assert(
        identical(
          as.character(as.Date(md[[field]])),
          as.character(as.Date(cfg_d[[field]]))
        ),
        paste("Configuration period mismatch:", field, key)
      )
    }
  }

  obs_file <- file.path(
    dirMain,
    "data/forcings/daily",
    basin,
    paste0(basin, "_input.nc")
  )

  assert(
    file.exists(obs_file),
    paste("Daily observations missing:", basin)
  )

  sim_d_file <- resolve_simulation_file(md$simulation_file)
  sim_h_file <- resolve_simulation_file(mh$simulation_file)

  qobs <- read_qobs(obs_file, cfg_d)

  prepared_d <- prepare_daily_evaluation(
    qobs_daily = qobs,
    qsim = readRDS(sim_d_file),
    simulation_timestep = "daily",
    timezone = cfg_d$timezone
  )

  prepared_h <- prepare_daily_evaluation(
    qobs_daily = qobs,
    qsim = readRDS(sim_h_file),
    simulation_timestep = "hourly",
    timezone = cfg_d$timezone
  )

  # Read continuous metrics already calculated by 05_evaluation.

  archived_d <- read_archived_metrics(
    evaluations$global_native,
    row_d,
    "daily"
  )

  archived_h <- read_archived_metrics(
    evaluations$global_daily,
    row_h,
    "hourly"
  )

  cat("PASS: archived continuous metrics available\n")

  # Strict pairing by identical calendar dates.

  d <- prepared_d$paired
  h <- prepared_h$paired

  assert(
    !anyDuplicated(d$date) &&
      !anyDuplicated(h$date),
    paste("Duplicate daily dates:", key)
  )

  common <- merge(
    d,
    h,
    by = "date",
    suffixes = c("_daily", "_hourly"),
    sort = TRUE
  )

  assert(
    nrow(common) > 0L,
    paste("No shared calendar dates:", key)
  )

  assert(
    identical(
      as.numeric(common$time_daily),
      as.numeric(common$time_hourly)
    ),
    paste("Common timestamps differ:", key)
  )

  assert(
    identical(common$qObs_daily, common$qObs_hourly),
    paste("Daily observations differ:", key)
  )

  common <- common[
    is.finite(common$qObs_daily) &
      common$qObs_daily >= 0 &
      is.finite(common$qSim_daily) &
      is.finite(common$qSim_hourly),
    ,
    drop = FALSE
  ]

  assert(
    nrow(common) > 0L,
    paste("No valid common observations:", key)
  )

  to_metric_input <- function(sim_col) {
    data.frame(
      time = common$time_daily,
      qObs = common$qObs_daily,
      qSim = common[[sim_col]]
    )
  }

  count_period <- function(x, period) {
    sum(
      x$time >= periods[[period]]$ti &
        x$time <= periods[[period]]$tf &
        is.finite(x$qObs) &
        x$qObs >= 0 &
        is.finite(x$qSim)
    )
  }

  period_names <- names(periods)

  n_daily <- vapply(
    period_names,
    function(p) count_period(d, p),
    integer(1)
  )

  n_hourly <- vapply(
    period_names,
    function(p) count_period(h, p),
    integer(1)
  )

  n_common <- vapply(
    period_names,
    function(p) {
      sum(
        common$time_daily >= periods[[p]]$ti &
          common$time_daily <= periods[[p]]$tf
      )
    },
    integer(1)
  )

  assert(
    all(n_common >= 10L),
    paste("Insufficient common days:", key)
  )

  # Every valid common day must be valid in both original series.

  assert(
    all(n_common <= n_daily) &&
      all(n_common <= n_hourly),
    paste("Invalid common-day coverage:", key)
  )

  select_metrics <- function(archived, n_valid, sim_col, resolution) {

    ix <- match(period_names, archived$period)

    assert(
      !anyNA(ix),
      paste("Missing archived metric periods:", resolution, key)
    )

    selected <- archived[
      ix,
      c("period", "NSE", "KGE.2009"),
      drop = FALSE
    ]

    selected$period <- as.character(selected$period)
    selected$source <- rep("05_evaluation", length(period_names))

    # Recalculate only periods where the original valid-day
    # coverage differs from the common-day coverage.

    needs_recalculation <- which(n_valid != n_common)

    for (j in needs_recalculation) {

      p <- period_names[[j]]

      recalculated <- calculate_metrics(
        to_metric_input(sim_col),
        basin,
        periods[p]
      )

      assert(
        nrow(recalculated) == 1L &&
          identical(as.character(recalculated$period), p),
        paste("Invalid paired metric calculation:", resolution, p, key)
      )

      selected$NSE[j] <- recalculated$NSE[[1L]]
      selected$KGE.2009[j] <- recalculated$KGE.2009[[1L]]
      selected$source[j] <- "recomputed_common_days"
    }

    selected
  }

  metrics_d <- select_metrics(
    archived_d,
    n_daily,
    "qSim_daily",
    "daily"
  )

  metrics_h <- select_metrics(
    archived_h,
    n_hourly,
    "qSim_hourly",
    "hourly"
  )

  cat("\nMetric provenance:\n")

  print(
    data.frame(
      period = period_names,
      daily = metrics_d$source,
      hourly = metrics_h$source
    ),
    row.names = FALSE
  )

  continuous <- data.frame(
    strategy = row_d$strategy,
    unit = row_d$unit,
    basin = basin,
    method = row_d$method,
    modelStep = if (is.null(md$modelStep)) {
      NA_integer_
    } else {
      as.integer(md$modelStep)
    },
    zDecision = as.character(md$zDecision),
    phase = if (is.null(md$phase)) {
      NA_character_
    } else {
      as.character(md$phase)
    },
    period = period_names,
    n_valid_days_daily = n_daily,
    n_valid_days_hourly = n_hourly,
    n_common_days = n_common,
    n_daily_only_days = n_daily - n_common,
    n_hourly_only_days = n_hourly - n_common,
    metric_source_daily = metrics_d$source,
    metric_source_hourly = metrics_h$source,
    NSE_daily = metrics_d$NSE,
    NSE_hourly = metrics_h$NSE,
    delta_NSE = metrics_h$NSE - metrics_d$NSE,
    KGE2009_daily = metrics_d$KGE.2009,
    KGE2009_hourly = metrics_h$KGE.2009,
    delta_KGE2009 = (
      metrics_h$KGE.2009 - metrics_d$KGE.2009
    ),
    metric_period_rule = md$metric_period_rule,
    daily_evaluation_dir = dirname(
      row_d$metadata_file[[1L]]
    ),
    hourly_evaluation_dir = dirname(
      row_h$metadata_file[[1L]]
    ),
    stringsAsFactors = FALSE
  )

  diagnostic <- list(
    identity = row_d[, keycols, drop = FALSE],
    daily = prepared_d$diagnostics,
    hourly = prepared_h$diagnostics,
    total_common_days = nrow(common),
    simulation_file_daily = sim_d_file,
    simulation_file_hourly = sim_h_file
  )

  print(
    continuous[, c(
      "period",
      "n_valid_days_daily",
      "n_valid_days_hourly",
      "n_common_days",
      "NSE_daily",
      "NSE_hourly",
      "delta_NSE",
      "KGE2009_daily",
      "KGE2009_hourly",
      "delta_KGE2009",
      "metric_source_daily",
      "metric_source_hourly"
    )],
    row.names = FALSE,
    digits = 9
  )

  list(continuous = continuous, diagnostic = diagnostic)
}

indices <- seq_along(matched_keys)
workers <- min(ncores, length(indices))
cat("Parallel workers:", workers, "\n")

pair_results <- if (workers == 1L) {
  lapply(indices, process_pair)
} else {
  parallel::mclapply(
    indices,
    process_pair,
    mc.cores = workers,
    mc.preschedule = TRUE,
    mc.set.seed = FALSE
  )
}

# mclapply() may return try-error/NULL for a failed child process.
# Never publish partial results or silently skip failed pairs.
valid_results <- vapply(
  pair_results,
  function(x) {
    is.list(x) &&
      !inherits(x, "try-error") &&
      is.data.frame(x$continuous) &&
      is.list(x$diagnostic)
  },
  logical(1L)
)

assert(
  length(pair_results) == length(matched_keys) && all(valid_results),
  paste(
    "One or more paired daily comparisons failed:",
    paste(matched_keys[which(!valid_results)], collapse = ", ")
  )
)

results <- lapply(pair_results, `[[`, "continuous")
diagnostics <- lapply(pair_results, `[[`, "diagnostic")

# ==============================================================================
# 5. Assemble and validate results
# ==============================================================================

paired <- do.call(rbind, results)
rownames(paired) <- NULL

paired_key <- makekey(
  paired,
  c(keycols, "modelStep", "period")
)

assert(
  !anyDuplicated(paired_key),
  "Duplicate paired continuous results"
)

paired <- paired[
  order(
    paired$strategy,
    paired$unit,
    paired$basin,
    paired$method,
    paired$period
  ),
  ,
  drop = FALSE
]

rownames(paired) <- NULL

comparison <- list(
  schema_version = "lse_continuous_comparisons_v1",
  source_evaluations_rds = input_file,
  source_schema_version = evaluations$schema_version,
  matched_simulations = length(matched_keys),
  n_unmatched_daily = length(
    setdiff(daily_keys, hourly_keys)
  ),
  n_unmatched_hourly = length(
    setdiff(hourly_keys, daily_keys)
  ),
  paired_continuous = paired,
  diagnostics = diagnostics
)

cat("\n===== FINAL VALIDATION =====\n")
cat("Matched simulation pairs:", length(matched_keys), "\n")
cat("Paired continuous rows:", nrow(paired), "\n")
cat("Common-day pairing completed\n")
cat("No flood metrics calculated\n")

# ==============================================================================
# 6. Publish consolidated comparison RDS
# ==============================================================================

if (check_only) {

  cat("\nCHECK MODE: NO FILES WRITTEN\n")

} else {

  assert(
    !file.exists(outdir) &&
      !dir.exists(outdir),
    paste("Refusing to overwrite existing output:", outdir)
  )

  parent <- dirname(outdir)

  assert(
    dir.exists(parent),
    paste("Output parent does not exist:", parent)
  )

  publish <- function() {

    stage <- tempfile(
      pattern = ".lse_continuous_stage_",
      tmpdir = parent
    )

    assert(
      dir.create(stage),
      paste("Cannot create staging directory:", stage)
    )

    on.exit({
      if (dir.exists(stage)) {
        unlink(stage, recursive = TRUE)
      }
    }, add = TRUE)

    saveRDS(
      comparison,
      file.path(stage, "continuous_comparisons.rds"),
      compress = "gzip"
    )

    assert(
      !file.exists(outdir) && !dir.exists(outdir),
      "Output appeared during staging"
    )

    assert(
      file.rename(stage, outdir),
      paste("Cannot publish continuous comparisons:", outdir)
    )
  }

  publish()

  cat("\nWROTE:", outdir, "\n")
  cat("Object: continuous_comparisons.rds\n")
}

cat("\nPAIRED CONTINUOUS ANALYSIS COMPLETE\n")
