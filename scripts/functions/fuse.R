# ==============================================================================
# Extract active parameter information for one FUSE configuration
# ==============================================================================

get_parameter_info <- function(fuse_settings_files, zDecision) {
  
  key <- paste0("zDecision_", zDecision)
  
  if (!key %in% names(fuse_settings_files$configs_to_params)) {
    stop("Unknown zDecision: ", zDecision)
  }
  
  mask <- fuse_settings_files$configs_to_params[[key]]$params
  rows <- which(mask == 1)
  
  if (!length(rows)) {
    stop("No active parameters for ", key)
  }
  
  params <- fuse_settings_files$params
  
  parameter_names <- vapply(
    strsplit(trimws(sub("!.*$", "", fuse_settings_files$zConstraints[params$row])), "\\s+"),
    function(x) x[14],
    character(1)
  )
  
  list(rows = rows, params = params, names = parameter_names[rows], mask = mask)
}


# ==============================================================================
# Prepare an isolated FUSE workspace for one basin
#
# Forcing, settings and structural-decision files are copied into a temporary
# workspace so concurrent basin runs do not interfere with each other.
# ==============================================================================

prepare_fuse_workspace <- function(dirMain, work_dir, basinID, zDecision, experiment) {
  
  paths <- project_paths(dirMain)
  
  ensure_dir(work_dir)
  
  input_dir <- ensure_dir(file.path(work_dir, "input"))
  settings_dir <- ensure_dir(file.path(work_dir, "settings"))
  output_dir <- ensure_dir(file.path(work_dir, "output"))
  
  decision_dir <- ensure_dir(file.path(settings_dir, "fuse_zDecisions"))
  control_dir <- ensure_dir(file.path(settings_dir, "fuse_control"))
  
  # Copy basin-specific forcing files.
  forcing_source <- file.path(paths$forcings, basinID)
  
  if (!dir.exists(forcing_source)) {
    stop("Missing forcing folder: ", forcing_source)
  }
  
  forcing_files <- list.files(forcing_source, full.names = TRUE)
  
  if (!length(forcing_files)) {
    stop("Forcing folder is empty: ", forcing_source)
  }
  
  ok <- file.copy(forcing_files, input_dir, overwrite = TRUE, recursive = TRUE)
  
  if (!all(ok)) {
    stop("Failed to copy one or more forcing files for basin ", basinID)
  }
  
  # Copy the canonical FUSE settings.
  settings_files <- list.files(paths$settings, full.names = TRUE)
  
  if (!length(settings_files)) {
    stop("No canonical settings found in ", paths$settings)
  }
  
  ok <- file.copy(settings_files, settings_dir, overwrite = TRUE, recursive = FALSE)
  
  if (!all(ok)) {
    stop("Failed to copy one or more settings files")
  }
  
  # Copy the structural-decision file required by the selected configuration.
  decision_file <- file.path(paths$decisions, paste0("fuse_zDecisions_", zDecision, ".txt"))
  
  if (!file.exists(decision_file)) {
    stop("Missing zDecision file: ", decision_file)
  }
  
  if (!file.copy(decision_file, decision_dir, overwrite = TRUE)) {
    stop("Could not copy ", decision_file)
  }
  
  # Build the basin/model FUSE control file directly for the current FUSE version.

  simulation_start <- as.POSIXct(experiment$simulation_start, tz = "Etc/GMT-12")
  simulation_end <- as.POSIXct(experiment$simulation_end, tz = "Etc/GMT-12")
  calibration_start <- as.POSIXct(experiment$calibration_start, tz = "Etc/GMT-12")
  calibration_end <- as.POSIXct(experiment$calibration_end, tz = "Etc/GMT-12")
  
  toml <- c(
    paste0("# FUSE control file for ", basinID, " - model ", zDecision),
    "",
    "[filepaths]",
    paste0('settings_dir = "', settings_dir, '/"'),
    paste0('input_dir    = "', input_dir, '/"'),
    paste0('output_dir   = "', output_dir, '/"'),
    "",
    "[input]",
    'hydromet_suffix  = "_input.nc"',
    'elevbands_suffix = "_elev_bands.nc"',
    "",
    "[model]",
    'constraints_file = "fuse_zConstraints_snow.txt"',
    'numerics_file    = "fuse_zNumerix.txt"',
    paste0('decisions_file = "fuse_zDecisions/fuse_zDecisions_', zDecision, '.txt"'),
    "",
    "[forcing_coords]",
    'time      = "time"',
    'latitude  = "latitude"',
    'longitude = "longitude"',
    "",
    "[hydromet_vars]",
    'precip = "pr"',
    'temp   = "temp"',
    'pet    = "pet"',
    'qobs   = "q_obs"',
    "",
    "[output]",
    paste0('model_id = "', zDecision, '"'),
    "variables = [",
    '  "q_instnt",',
    '  "q_routed",',
    '  "q_obs"',
    "]",
    "",
    "[run_periods]",
    paste0('date_start_sim  = "',format(simulation_start + 86400, "%Y-%m-%d"),'"'), # The simulation therefore starts at the end of the first forcing interval
    paste0('date_end_sim    = "', format(simulation_end, "%Y-%m-%d"), '"'),
    paste0('date_start_eval = "', format(calibration_start, "%Y-%m-%d"), '"'),
    paste0('date_end_eval   = "', format(calibration_end, "%Y-%m-%d"), '"'),
    'numtim_sub_str = "-9999"',
    "",
    "[calibration]",
    paste0('metric  = "', experiment$metric, '"'),
    paste0('transfo = "', experiment$transformation, '"'),
    "",
    "[sce]",
    "maxn   = 10000",
    "kstop  = 3",
    "pcento = 0.001"
  )
  
  config_file <- file.path(control_dir, paste0("fuse_control_", basinID, "_", zDecision, ".toml"))
  
  writeLines(toml, config_file)
  
  list(
    input_dir = input_dir,
    settings_dir = settings_dir,
    output_dir = output_dir,
    config_file = config_file
  )
}


# ==============================================================================
# Read observed streamflow from a FUSE forcing file
# ==============================================================================

read_qobs <- function(input_file) {
  
  nc <- ncdf4::nc_open(input_file)
  on.exit(ncdf4::nc_close(nc))
  
  time_raw <- ncdf4::ncvar_get(nc, "time")
  units <- ncdf4::ncatt_get(nc, "time", "units")$value
  
  origin <- as.Date(sub("^(days|hours) since ", "", units))
  
  if (grepl("^hours since", units)) {
    dates <- origin + time_raw / 24
  } else {
    dates <- origin + time_raw
  }
  
  data.frame(
    date = as.Date(dates),
    qObs_mmd = ncdf4::ncvar_get(nc, "q_obs")
  )
}


# ==============================================================================
# Compute hydrological performance metrics
#
# Metrics are calculated independently over the calibration and evaluation
# periods after removing dates with missing observed or simulated streamflow.
# ==============================================================================

compute_flow_metrics <- function(qsim, qobs, basinID, periods) {
  
  df <- merge(qsim, qobs, by = "date")
  
  out <- vector("list", length(periods))
  names(out) <- names(periods)
  
  for (i in seq_along(periods)) {
    
    ti <- periods[[i]]$ti
    tf <- periods[[i]]$tf
    
    rows <- which(
      df$date >= ti &
        df$date <= tf &
        !is.na(df$qObs_mmd) &
        df$qObs_mmd >= 0 &
        !is.na(df$qSim_mmd)
    )
    
    if (length(rows) < 10L) {
      return(NULL)
    }
    
    sim <- df$qSim_mmd[rows]
    obs <- df$qObs_mmd[rows]
    
    alpha <- stats::sd(sim) / stats::sd(obs)
    beta <- mean(sim) / mean(obs)
    r <- suppressWarnings(stats::cor(obs, sim, method = "pearson"))
    
    KGE <- if (is.finite(r)) {
      1 - sqrt((1 - alpha)^2 + (1 - beta)^2 + (1 - r)^2)
    } else {
      -100
    }
    
    NSE <- 1 - sum((sim - obs)^2) / sum((obs - mean(obs))^2)
    
    out[[i]] <- data.frame(
      basin_ID = basinID,
      period = names(periods)[i],
      ti = ti,
      tf = tf,
      NSE = NSE,
      KGE.2009 = KGE,
      alpha = alpha,
      beta = beta,
      r = r
    )
  }
  
  do.call(rbind, out)
}


# ==============================================================================
# Run FUSE for one normalized parameter set
#
# Normalized emulator parameters are converted back to the physical FUSE
# parameter ranges, written to the constraint file, and evaluated with FUSE.
# ==============================================================================

run_fuse <- function(params_normalized, basinID, zDecision, fuse_settings_files,
                     work_dir, fuse_exe, qObs, periods, timeout_seconds = 60L,
                     store_hydrograph = FALSE) {
  
  info <- get_parameter_info(fuse_settings_files, zDecision)
  
  if (length(params_normalized) != length(info$rows)) {
    stop("Wrong number of normalized parameters")
  }
  
  if (any(!is.finite(params_normalized)) || any(params_normalized < 0 | params_normalized > 1)) {
    stop("Parameters must be finite in [0,1]")
  }
  
  
  # ============================================================================
  # Convert normalized parameters to the physical FUSE parameter ranges
  # ============================================================================
  
  params <- info$params
  
  lo <- params$min[info$rows]
  hi <- params$max[info$rows]
  
  params$default[info$rows] <- round(lo + params_normalized * (hi - lo), 3)
  params$final_line <- NA_character_
  
  for (i in seq_len(nrow(params))) {
    
    value <- format(params$default[i], nsmall = 3)
    nspace <- max(1L, 9L - nchar(value))
    
    params$final_line[i] <- paste0(
      params$text.1[i],
      params$text.2[i],
      strrep(" ", nspace),
      value,
      params$text.b[[i]]
    )
  }
  
  zc <- fuse_settings_files$zConstraints
  zc[params$row] <- params$final_line
  
  writeLines(zc, file.path(work_dir, "settings", "fuse_zConstraints_snow.txt"))
  
  
  # ============================================================================
  # Run FUSE
  # ============================================================================
  
  config_file <- file.path(work_dir, "settings", "fuse_control", paste0("fuse_control_", basinID, "_", zDecision, ".toml"))
  
  if (!file.exists(config_file)) {
    stop("Missing basin TOML: ", config_file)
  }
  
  if (!file.exists(fuse_exe)) {
    stop("FUSE executable not found: ", fuse_exe)
  }
  
  output_file <- file.path(work_dir, "output", paste0(basinID, "_", zDecision, "__runs_def.nc"))
  
  if (file.exists(output_file) && !file.remove(output_file)) {
    stop("Could not remove old output: ", output_file)
  }
  
  log_file <- file.path(work_dir, "output", "fuseLog.txt")
  fuse_args <- c("-d", basinID, "-c", config_file, "-m", "def")
  
  # GNU timeout is used on HPC, while gtimeout provides the same functionality
  # on macOS when installed through coreutils.
  timeout_cmd <- Sys.which("timeout")
  
  if (!nzchar(timeout_cmd)) {
    timeout_cmd <- Sys.which("gtimeout")
  }
  
  if (nzchar(timeout_cmd)) {
    
    exit_code <- system2(
      timeout_cmd,
      args = c(paste0(timeout_seconds, "s"), fuse_exe, fuse_args),
      stdout = log_file,
      stderr = log_file
    )
    
  } else {
    
    warning("Neither timeout nor gtimeout found; running FUSE without an enforced timeout")
    
    exit_code <- system2(
      fuse_exe,
      args = fuse_args,
      stdout = log_file,
      stderr = log_file
    )
  }
  
  if (exit_code == 124L) {
    return(list(ok = FALSE, reason = "timeout"))
  }
  
  if (exit_code != 0L) {
    return(list(ok = FALSE, reason = paste0("exit_", exit_code)))
  }
  
  if (!file.exists(output_file) || file.size(output_file) == 0) {
    return(list(ok = FALSE, reason = "missing_output"))
  }
  
  
  # ============================================================================
  # Read simulated discharge and calculate performance metrics
  # ============================================================================
  
  nc <- tryCatch(ncdf4::nc_open(output_file), error = function(e) NULL)
  
  if (is.null(nc)) {
    return(list(ok = FALSE, reason = "cannot_open_output"))
  }
  
  on.exit(try(ncdf4::nc_close(nc)), add = TRUE)
  
  time_raw <- ncdf4::ncvar_get(nc, "time")
  units <- ncdf4::ncatt_get(nc, "time", "units")$value
  
  origin <- as.Date(sub("^(days|hours) since ", "", units))
  
  dates <- if (grepl("^hours since", units)) {
    origin + time_raw / 24
  } else {
    origin + time_raw
  }
  
  qsim <- data.frame(
    date = as.Date(dates),
    qSim_mmd = ncdf4::ncvar_get(nc, "q_routed")
  )
  
  metrics <- compute_flow_metrics(qsim, qObs, basinID, periods)
  
  if (is.null(metrics)) {
    return(list(ok = FALSE, reason = "insufficient_metric_data"))
  }
  
  ans <- list(ok = TRUE, qMetrics = metrics)
  
  if (store_hydrograph) {
    ans$qSim <- qsim
  }
  
  ans
}