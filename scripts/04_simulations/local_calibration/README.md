# Local FUSE calibration

`01_run_local_calibration.R` calibrates one basin with FUSE SCE
and archives the hydrograph simulated using the optimal parameters.

## Usage

Rscript scripts/04_simulations/local_calibration/01_run_local_calibration.R \
  <basinID> <experiment_dir> <run|archive> \
  <work_dir> <config_file> <dirMain>

## Modes

- `run`: prepare a new FUSE workspace, execute `-m sce`,
  reproduce the optimum with `-m opt`, validate and archive results.
- `archive`: validate and archive results from an existing
  completed SCE/OPT workspace, without executing FUSE.

The model structure (`zDecision`), timestep, calibration period
and objective function are read from the experiment configuration.

SCE settings (maxn, kstop, pcento) are currently defined in
`prepare_fuse_workspace()` in `scripts/functions/fuse.R`.

No global timeout is imposed on SCE.

## Selection: best

For local calibration, `best` means the optimal parameter set
returned by SCE, evaluated on the temporal calibration period.

It does not mean the best emulator-predicted candidate.

There is no spatial train/test split for local calibration.
Independent temporal evaluation is performed afterwards.

## Outputs

For each basin:

- `outputs/zDecision_<zDecision>/<basinID>/sce/`
  contains SCE parameters, optimal parameters, OPT simulation,
  diagnostic logs and the FUSE control file.
- `hydrographs/zDecision_<zDecision>/<basinID>/sce/`
  contains `qSim_selected.rds` and `metadata.rds`.
- `evaluation/zDecision_<zDecision>/<basinID>/sce/`
  is produced separately by the generic evaluation launcher.

Existing calibration outputs are never overwritten.

## Evaluation

Rscript scripts/05_evaluation/02_evaluate_experiment.R \
  <experiment_dir> <config_file> <dirMain>

The evaluator uses archived hydrographs and never runs FUSE.
