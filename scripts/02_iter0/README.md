# Initial FUSE ensemble (`iter0`)

## Purpose

This module generates the initial FUSE parameter ensemble used to train the
large-sample emulators.

For each basin and FUSE structural decision (`zDecision`), it samples
normalized parameters using Latin Hypercube Sampling (LHS), runs FUSE,
and evaluates the simulations over the configured calibration and evaluation
periods.

`iter0` belongs to the emulator workflow. It is independent of the local
SCE calibration workflow.

## Inputs and configuration

The module uses:

- `config/basins.txt`: selected basin IDs, one per line.
- `config/experiment_daily.R` or `config/experiment_hourly.R`: experiment
  configuration.
- Prepared FUSE forcing files, settings, structural decisions and metadata
  from `01_prepare`.

Relevant experiment settings include:

- `timestep`: `daily` or `hourly`.
- `zDecision`: one or more FUSE structural decisions.
- `nIter0`: number of initial parameter vectors per basin and decision.
- `seed`: random seed used for reproducible sampling.
- Calibration and evaluation periods required by FUSE evaluation.

The current daily and hourly configurations use `zDecision = "126"`,
`nIter0 = 500` and `seed = 1234`.

Basin IDs are read using the shared `read_basin_ids()` function. Empty
lines, duplicate IDs and malformed basin lists are rejected.

## Running locally

Run from the repository root:

```bash
DIR_MAIN="$PWD" \
CONFIG_FILE="$PWD/config/experiment_daily.R" \
bash scripts/02_iter0/run_iter0_local.sh
```

For the hourly experiment, replace the configuration path with
`config/experiment_hourly.R`.

The launcher requires R, the necessary R packages, FUSE dependencies
and GNU Parallel.

By default, it runs four concurrent processes. To change this:

```bash
DIR_MAIN="$PWD" \
CONFIG_FILE="$PWD/config/experiment_hourly.R" \
NCORES=8 \
bash scripts/02_iter0/run_iter0_local.sh
```

When multiple structural decisions are configured, the launcher runs
every selected basin for every configured decision.

To restrict execution to one configured decision, set `ZDECISION`:

```bash
DIR_MAIN="$PWD" \
CONFIG_FILE="$PWD/config/experiment_daily.R" \
ZDECISION=126 \
bash scripts/02_iter0/run_iter0_local.sh
```

Each basin/decision combination receives an independent temporary FUSE
workspace.

## Running on ARC

On ARC, submit from the repository root:

```bash
bash scripts/02_iter0/submit_iter0_hpc_arc.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

Use `config/experiment_hourly.R` for the hourly experiment.

The submitter validates the basin list and configured decisions, then
submits one Slurm job array per selected structural decision.

Each array task processes one basin and one decision using
`run_iter0_hpc_arc.slurm`.

To submit only one configured decision:

```bash
ZDECISION=126 bash scripts/02_iter0/submit_iter0_hpc_arc.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

The ARC runner requests one CPU, 4 GB per CPU and 12 hours per task.

## Running on FIR

On FIR, submit from the repository root:

```bash
bash scripts/02_iter0/submit_iter0_hpc_fir.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

The optional `ZDECISION` variable works as on ARC.

Each array task runs one basin/decision combination through
`run_iter0_hpc_fir.slurm`.

The FIR runner requests one CPU, 4 GB and 24 hours per task, using
the configured Slurm account.

On both clusters, Slurm logs are written under:

```text
logs/iter0/
```

## Outputs

For a given timestep, basin and structural decision, the output is:

```text
outputs/<timestep>/iter0/
  zDecision_<zDecision>/
    <basinID>/
      iter0_<basinID>_zDec_<zDecision>.RData
```

Each `.RData` file contains an object named `iter0` with:

- `basinID`
- `zDecision`
- `parameter_names`
- `params_normalized`
- `KGE_calibration`
- `KGE_evaluation`
- `qMetrics`
- `seed`

These results are consumed by the emulator workflow through
`scripts/functions/emulator_data.R`.

The initial parameter ensemble is reproducible for a fixed configuration
and basin ID. Its random seed incorporates the configured seed and basin ID.

## Existing results, failures and reruns

Existing results are protected against accidental replacement.

If an output already exists, `01_run_iter0.R` stops unless its optional
`--force` argument is explicitly supplied.

The local launcher and HPC submitters do not automatically skip completed
basins or forward `--force`. Rerunning an entire completed batch can
therefore produce expected "result already exists" errors.

To recalculate a specific basin, invoke `01_run_iter0.R` directly with
the appropriate basin, configured decision, independent workspace,
configuration file and repository root. Add `--force` only when replacing
an existing result is intentional.

The result is first saved and checked in a temporary `.RData` file in the
destination directory, then renamed to its final filename.

There is no partial checkpointing or automatic resume. If a calculation
is interrupted before the final result is written, rerun that
basin/decision combination from the beginning.

Do not run two simultaneous calculations targeting the same
basin/decision output directory.

## Scope and reproducibility

A repository clone should represent one fixed experiment and timestep.
Daily and hourly results use separate output directories.

The module supports multiple configured structural decisions for `iter0`,
but downstream workflow stages must be checked separately before assuming
full multi-decision support across the repository.

This module does not perform local SCE calibration or define spatial
training/validation splits.
