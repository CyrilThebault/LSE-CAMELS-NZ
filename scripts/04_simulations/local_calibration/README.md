# Local FUSE calibration

`01_run_local_calibration.R` calibrates one basin with FUSE SCE
and archives the hydrograph simulated using the optimal parameters.

## Prerequisites and independence

Local FUSE calibration is an independent simulation branch.

It requires the prepared FUSE inputs for the selected basin and the
fixed experiment configuration, but does not depend on:

- The initial `iter0` database, which is used only by the emulator workflow.
- Emulator training, refinement, or candidate selection.
- Spatial train/test experiment splits.

Each basin is calibrated directly with FUSE SCE. The optimum is then
reproduced with FUSE OPT and archived for subsequent evaluation.

Local calibration and emulator simulations can therefore be executed
independently after their shared input preparation.

## Usage

The low-level runner accepts six positional arguments, in this order:

```text
Rscript scripts/04_simulations/local_calibration/01_run_local_calibration.R \
  BASIN_ID EXPERIMENT_DIR MODE WORK_DIR CONFIG_FILE DIR_MAIN
```

This is an interface description, not a command to execute verbatim.
`MODE` must be either `run` or `archive`.

For normal basin campaigns, use the local or HPC launchers below.

## Modes

- `run`: prepare a new FUSE workspace, execute `-m sce`,
  reproduce the optimum with `-m opt`, validate and archive results.
- `archive`: validate and archive results from an existing
  completed SCE/OPT workspace, without executing FUSE.

The model structure (`zDecision`), timestep, calibration period
and objective function are read from the experiment configuration.

SCE settings (`maxn`, `kstop`, `pcento`) are defined in
`config/experiment_daily.R` and `config/experiment_hourly.R`, under
`experiment$local_calibration$sce`.

The shared `prepare_fuse_workspace()` function reads and validates these
settings without fallback values. The configured values are:

- `maxn = 10000`
- `kstop = 3`
- `pcento = 0.001`

These values preserve the previous FUSE control-file settings.
All callers of `prepare_fuse_workspace()`, including iter0 and emulator
simulations, require an experiment configuration containing this section.

No global timeout is imposed on SCE.

## Campaign launchers and HPC submission

All commands below assume they are executed from the repository root.

### Local campaign

The local launcher uses environment variables rather than positional
arguments.

Example: inspect the daily campaign without executing FUSE:

```bash
DIR_MAIN="$PWD" \
CONFIG_FILE="$PWD/config/experiment_daily.R" \
EXPERIMENT_DIR="$PWD/experiments/daily/localcalib/all_basins" \
DRY_RUN=1 \
bash scripts/04_simulations/local_calibration/run_local_calibration_local.sh
```

To use hourly data, replace `daily` with `hourly` in both
`CONFIG_FILE` and `EXPERIMENT_DIR`.

After reviewing the dry run, remove `DRY_RUN=1` to execute the
campaign. The optional `NCORES` variable controls the number of
parallel local calibration processes.

### ARC submission

Example: validate the daily submission without submitting any jobs:

```bash
DRY_RUN=1 bash scripts/04_simulations/local_calibration/submit_local_calibration_hpc_arc.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

Run this submission command on ARC without `DRY_RUN=1` to submit
the actual Slurm job array.

### FIR submission

Example: validate the daily submission without submitting any jobs:

```bash
DRY_RUN=1 bash scripts/04_simulations/local_calibration/submit_local_calibration_hpc_fir.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

Run this submission command on FIR without `DRY_RUN=1` to submit
the actual Slurm job array.

For hourly experiments, use `config/experiment_hourly.R` instead.

### Basin selection and output paths

The canonical basin list defaults to `config/basins.txt`.

The optional `BASIN_FILE` environment variable overrides this path.

The shared R function `read_basin_ids()` validates the selected basin
list. The number of basins is determined dynamically from this list.

For Slurm submissions, `NBASINS` is computed as
`length(read_basin_ids(BASIN_FILE))`.

The Slurm array indices range from `1` to `NBASINS`
(`--array="1-$NBASINS"`).

Each Slurm array index selects the corresponding basin from the
validated list. No basin count is hard-coded in the launchers.

The timestep and `zDecision` are read from the experiment
configuration.

The default HPC output directory is:

```text
experiments/<timestep>/localcalib/all_basins
```

The optional `EXPERIMENT_DIR` environment variable can override
the HPC output directory and must contain an absolute path.

The local launcher requires `DIR_MAIN`, `CONFIG_FILE`, and
`EXPERIMENT_DIR` to be explicitly defined.

### Input integrity checks

At ARC/FIR submission, SHA-256 fingerprints are calculated for
`BASIN_FILE` and `CONFIG_FILE`.

These fingerprints describe the contents of the two input files.
They are not basin counts or scientific parameters.

Each Slurm task verifies the fingerprints before reading its
configuration and basin list. A missing or mismatched fingerprint
stops the task before calibration.

The checks detect changes between submission and task startup.
They do not make the files immutable during execution.

## Archive preflight

The local, ARC and FIR launchers use
`local_calibration_archive_status()` from
`scripts/functions/local_calibration.R`.

The validator distinguishes three archive states:

- `absent`: no existing archive; calibration may proceed.
- `complete`: required files are nonempty and the SCE and OPT
  completion markers are present; calibration is skipped.
- `incomplete`: missing or empty files, or missing completion
  markers; execution stops rather than silently overwriting results.

This is a lightweight archive preflight. The runner performs the
scientific validation of the NetCDF outputs, simulated discharge,
time axis and optimization metrics before publishing results.

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

The generic evaluator accepts three positional arguments:

```text
Rscript scripts/05_evaluation/02_evaluate_experiment.R \
  EXPERIMENT_DIR CONFIG_FILE DIR_MAIN
```

The names above are placeholders for actual paths.

The evaluator uses archived hydrographs and never runs FUSE.
