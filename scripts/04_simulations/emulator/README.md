# Large-Sample Emulator simulations

This module trains Large-Sample Emulators (LSE), searches the FUSE
parameter space and evaluates proposed candidates using FUSE.

The same workflow supports daily and hourly experiments. The execution
scripts use `config/experiment_daily.R` or `config/experiment_hourly.R` to
select timestep, model structure and refinement settings. The unified
`config/experiment.R` describes the broader campaign and is currently used
by the read-only planner, not directly by the simulation launchers.

Supported emulator methods are `RF`, `GBMv01` and `GBMv02`.

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

- `00_plan_LSE_campaign.R`: read-only `--dry-run` inventory and validation
  of configured spatial experiments; it does not execute the workflow.
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
be available. The planner checks spatial directory structure; it does not
validate all model, GA or FUSE result files.

### Inspect the campaign without running simulations

From the repository root:

```bash
cd "$(git rev-parse --show-toplevel)"
Rscript scripts/04_simulations/emulator/00_plan_LSE_campaign.R \
  --dry-run
```

To inspect one existing k-fold partition and selected methods:

```bash
cd "$(git rev-parse --show-toplevel)"
Rscript scripts/04_simulations/emulator/00_plan_LSE_campaign.R \
  --dry-run --timestep daily --split kfold --fold fold_01 \
  --emulator RF,GBMv02
```

The planner reads `config/experiment.R`, supports `--timestep`, `--split`,
`--fold` and `--emulator` filters, and requires `--dry-run`. Fold and mode
statuses distinguish missing partitions, validation failures and validated
partitions containing existing artifacts (`VALIDATED_PROTECTED`). The mode
summary also audits coverage across all configured folds, even when one
fold is selected. A protected folder must not be interpreted as evidence
that all emulator results are complete.

### Local

The local launcher requires GNU Parallel.

```bash
cd "$(git rev-parse --show-toplevel)"
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"
export EXPERIMENT_DIR="$DIR_MAIN/experiments/daily/kfold/fold_01"
export NCORES=4

bash scripts/04_simulations/emulator/run_LSE_split_local.sh
```

To select two methods and resume an interrupted local workflow, after
inspecting the intended fold and its outputs:

```bash
cd "$(git rev-parse --show-toplevel)"
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"
export EXPERIMENT_DIR="$DIR_MAIN/experiments/daily/kfold/fold_01"
export NCORES=4
export EMULATORS="RF,GBMv02"

bash scripts/04_simulations/emulator/run_LSE_split_local.sh --resume
```

**These launcher commands execute real training, GA and FUSE work whenever
required outputs are missing.** Do not use them as read-only validation
commands on historical campaigns. For hourly experiments, use
`experiment_hourly.R` and the corresponding directory under
`experiments/hourly/`.

`EMULATORS` is an optional comma-separated subset of configured methods;
when unset, all configured emulators are selected. `ZDECISION` and `NREFINE`
default to the resolution-specific configuration and may be overridden.
`NCORES` controls local parallel execution. `--resume` is a local launcher
option passed through to the three scientific scripts; HPC submitter
support for the flag has not been established by this refactoring.

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

For HPC, consult the submission scripts and the validated partition
workflow before launching jobs. These HPC commands submit jobs; they are
not dry runs. The local `--resume` forwarding tests do not establish that
HPC submission scripts automatically forward this option.

## Outputs

Within each experiment split, results are organized under:

`outputs/zDecision_<zDecision>/`

- `models/emulator_step_<step>_<emulator>.RData` contains a trained
  emulator for the specified refinement step.
- `<phase>/<basinID>/candidates_step_<step>_<emulator>.RData` is the
  current per-emulator candidate file. GA creates it; FUSE evaluation
  updates that same file with results and provenance.
- `<phase>/<basinID>/candidates_step_<step>.RData` is the **historical
  combined format**, containing rows for multiple emulators. It can be
  read through `read_emulator_candidates()` but is not rewritten by the
  new GA or FUSE scripts.

The reader rejects an ambiguous combination of historical and individual
files for the same emulator and step. Individual candidate writes are
protected by per-file lock directories (`.lock`) and temporary-file
serialization followed by atomic renaming. Interrupted lock directories
are not automatically removed: inspect the running job and any partial
workspace before considering manual cleanup.

### Resuming the local workflow

Each scientific script accepts the optional `--resume` flag and an optional
`--emulator RF,GBMv02` method filter. The wrapper forwards `--resume` to
training, GA and FUSE candidate evaluation. Without `--resume`, the original
refusal to overwrite existing outputs is retained.

| Stage | `SKIP` | `RUN` | `STOP` |
| --- | --- | --- | --- |
| Training | Existing compatible model, with checked metadata and structure | Model absent | Existing unreadable or inconsistent model |
| GA | Existing compatible candidate rows in either supported format | Candidate file absent | Invalid, incomplete or ambiguous candidate file |
| FUSE | Complete candidate evaluation, including a recorded FUSE failure | Unevaluated candidates in an individual file, with no existing method workspace | Missing candidates, partial evaluation, inconsistent provenance, historical unevaluated file or existing workspace |

The checks occur per selected method (and per basin/step for GA and FUSE).
They do **not** continue halfway through an interrupted candidate loop. A
failed FUSE run with an explicit, complete failure record can count as
evaluated; an incomplete file or leftover workspace must be examined
rather than silently retried. A completed legacy file is skipped in
`--resume` mode and is never rewritten.

`--resume` may still launch substantial new computations when some files
are missing. It does not validate full campaign completeness or promise
bit-for-bit reproduction of outputs created under earlier random seeds.

## Selected FUSE simulation

The selected candidate is the rank-1 candidate according to the
emulator-predicted score (`eNKGE`) for the specified basin, emulator,
refinement step and phase.

It is not selected using the observed FUSE calibration or evaluation KGE.

`04_reproduce_selected_FUSE.R` reads either historical combined or
individual candidate files, retaining the original row index and candidate
source in reproduction metadata when available. It provides two actions:

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

Archived simulations are evaluated by
`scripts/05_evaluation/02_evaluate_experiment.R`, using an experiment
directory, the matching daily/hourly configuration, and the repository
root. Consult the evaluation module README for a complete command with
verified paths before launching it.

The evaluator never runs FUSE.

See `scripts/05_evaluation/README.md` for evaluation details and the
interpretation of the selected `best` simulation.
