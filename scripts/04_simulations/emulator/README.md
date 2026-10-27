# Large-Sample Emulator simulations

This module trains Large-Sample Emulators (LSE), searches the FUSE
parameter space and evaluates proposed candidates using FUSE.

The same workflow supports daily and hourly experiments. The timestep,
model structure, emulator methods and refinement settings are defined
in the experiment configuration.

## Workflow

Each experiment split contains `train_basins.txt` and `test_basins.txt`.

The workflow follows these steps:

1. Train the initial emulators (step 0) from the immutable iter0 database.
2. Search the parameter space and evaluate FUSE candidates on test basins.
3. Generate and evaluate new candidates on training basins.
4. Retrain the emulators using available training-basin results.
5. Evaluate each refined emulator on test basins.

Steps 3-5 are repeated according to `nRefinementSteps`.

Test-basin results are used for evaluation only. They never contribute
to emulator training or refinement.

## Scripts

- `01_train_emulator.R`: build the training dataset and fit the
  configured emulators for one refinement step.
- `02_search_parameter_space.R`: propose FUSE parameter candidates
  for one basin and phase (`train` or `test`).
- `03_run_FUSE_candidates.R`: execute FUSE for the proposed candidates
  and record their simulation metrics.
- `04_reproduce_selected_FUSE.R`: reproduce the rank-1 candidate and
  archive its simulated hydrograph after validating the results.

## Running an experiment

Experiment splits, iter0 results and prepared FUSE inputs must already
be available.

### Local

The local launcher requires GNU Parallel.

```bash
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"
export EXPERIMENT_DIR="$DIR_MAIN/experiments/daily/kfold/fold_01"
export NCORES=4

bash scripts/04_simulations/emulator/run_LSE_split_local.sh
```

For hourly experiments, use `experiment_hourly.R` and the corresponding
directory under `experiments/hourly/`.

### ARC HPC

Submit all valid splits of an experiment:

```bash
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"

bash scripts/04_simulations/emulator/submit_LSE_experiment_hpc_arc.sh \
  "$DIR_MAIN" "$CONFIG_FILE" kfold
```

### FIR HPC

The equivalent FIR submission script is:

```bash
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"

bash scripts/04_simulations/emulator/submit_LSE_experiment_hpc_fir.sh \
  "$DIR_MAIN" "$CONFIG_FILE" kfold
```

Both HPC submission scripts discover split directories containing
`train_basins.txt` and `test_basins.txt` and submit one Slurm job per split.

Before submitting any job, both scripts run
`scripts/03_experiments/02_validate_experiment_splits.R` for the selected
experiment mode (`allseen`, `loo`, `kfold` or `cluster`). This read-only
validation checks basin coverage, train/test consistency and the
mode-specific partition rules. If validation fails, no jobs are submitted.

In particular, incomplete LOO experiments are rejected even if their
existing fold directories contain valid train/test files.

`ZDECISION` and `NREFINE` default to the configuration values and may
be overridden using environment variables. The local launcher also
accepts `NCORES`.

## Outputs

Within each experiment split, results are organized under:

`outputs/zDecision_<zDecision>/`

- `models/emulator_step_<step>_<emulator>.RData` contains a trained
  emulator for the specified refinement step.
- `<phase>/<basinID>/candidates_step_<step>.RData` contains proposed
  parameter candidates and, after FUSE execution, their simulation metrics.

Candidate files are shared by the configured emulator methods.
Parameter search creates the candidate file, and FUSE evaluation
subsequently updates it with simulated performance.

Existing model and candidate outputs are protected against accidental
retraining or repeated evaluation. Completed FUSE candidate results
are written to a temporary file before replacing the original file.

An interrupted run is not automatically resumed. Existing outputs
must be inspected before attempting to rerun an incomplete workflow.

## Selected FUSE simulation

The selected candidate is the rank-1 candidate according to the
emulator-predicted score (`eNKGE`) for the specified basin, emulator,
refinement step and phase.

It is not selected using the observed FUSE calibration or evaluation KGE.

`04_reproduce_selected_FUSE.R` provides two actions:

- `check`: validate the selected candidate and required inputs without
  executing FUSE.
- `run`: reproduce the selected FUSE simulation, verify its calibration
  and evaluation KGE against the stored candidate results, and archive
  the simulated hydrograph and metadata.

Reproduction requires agreement in both KGE values within `1e-8`.
Existing archived hydrographs are not overwritten.

Reproduction and archiving are separate from parameter-space searching
and candidate evaluation.

## Evaluation

Archived simulations are evaluated using:

```text
Rscript scripts/05_evaluation/02_evaluate_experiment.R \
  EXPERIMENT_DIR CONFIG_FILE DIR_MAIN
```

The evaluator never runs FUSE.

See `scripts/05_evaluation/README.md` for evaluation details and the
interpretation of the selected `best` simulation.
