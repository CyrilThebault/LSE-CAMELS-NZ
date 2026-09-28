# Central configuration for the daily lumped CAMELS-NZ LSE workflow.
# All scripts source this file through scripts/functions/common.R.

local_machine <- Sys.info()[["sysname"]] == "Darwin"

# Root can be overridden without editing this file:
# export ROOT=/path/to/ROOT
root <- Sys.getenv("ROOT", unset = if (local_machine) {
  "/Users/cyrilthebault/ESNZ"
} else {
  "/work/comphyd_lab/users/cyril.thebault/ESNZ"
})

experiment <- list(
  dataset        = "CAMELS-NZ",
  timestep       = "daily",
  spatialisation = "Lumped",
  forcing        = "VCSN",
  zDecision      = "126",

  simulation_start = as.Date("1987-01-01"),
  simulation_end   = as.Date("2009-12-31"),
  calibration_start = as.Date("1989-01-01"),
  calibration_end   = as.Date("1998-12-31"),
  evaluation_start  = as.Date("1999-01-01"),
  evaluation_end    = as.Date("2009-12-31"),

  metric         = "KGE",
  transformation = "1",

  nIter0 = 500L,
  nRefinementSteps = 2L,

  emulators = c("RF", "GBMv01", "GBMv02"),
  seed = 1234L,

  ga_population  = 100L,
  ga_generations = 100L,
  nCandidates    = 100L,

  rf_trees = 100L,
  rf_mtry_fraction = 0.30,
  xgb_nrounds = 2000L,
  xgb_early_stopping = 20L,

  fuse_timeout_seconds = 60L,
  store_hydrographs = FALSE,

  paths = list(
    camels_nz = file.path(root, "02_DATA", "CAMELS-NZ"),
    fuse_template = file.path(root, "02_DATA", "FUSE-staging", "fuse_template"),
    fuse_exe = file.path(root, "04_TOOLS", "fuse-staging", "bin", "fuse.exe")
  )
)
