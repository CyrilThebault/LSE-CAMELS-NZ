# 03_experiments — Spatial experiment splits

This module creates and validates the spatial train/test partitions used
by the LSE emulator workflow.

Partition creation is independent of simulation, evaluation and analysis.
Experiments can therefore be prepared and executed one at a time.

Local SCE calibration is independent of these spatial splits.

## Scripts

| Script | Purpose |
| --- | --- |
| `01_create_experiment_splits.R` | Generate partitions for one experiment mode |
| `02_validate_experiment_splits.R` | Validate existing partitions without modifying them |
| `run_create_experiment_splits.sh` | Select, create and automatically validate experiment modes |

The shell launcher is portable across macOS, ARC and FIR, provided that
Bash and R are available. Split creation does not require Slurm.

## Configuration

The daily and hourly configurations are:

- `config/experiment_daily.R`
- `config/experiment_hourly.R`

They define the available spatial experiments:

```r
split_modes = c("allseen", "loo", "kfold", "cluster"),
kfold_K = 5L,
cluster_column = "Climate Zone",
```

The experiment seed is specified separately by `experiment$seed`.
The selected basin population comes from `config/basins.txt`.

The `cluster` mode groups basins by the `Climate Zone` field in
`data/useful_files/attributes.RData`. Despite its generic mode name,
this is a leave-one-climate-zone-out experiment.

With 256 selected basins, five K-fold partitions and six climate zones,
the expected number of folds is:

| Mode | Folds | Test basins |
| --- | ---: | --- |
| `allseen` | 1 | All basins |
| `loo` | 256 | One basin per fold |
| `kfold` | 5 | Disjoint, approximately balanced groups |
| `cluster` | 6 | One complete climate zone per fold |

The fold counts depend on the current basin list and configuration.

## Recommended workflow

Work on one spatial experiment at a time:

1. Create and validate the selected experiment partitions.
2. Run the emulator simulations for those folds.
3. Evaluate and collect the results.
4. Move to the next experiment.

Creating all configured partitions at once is also possible, but is
not required.

Run commands from the repository root.

### Create one experiment

Daily LOO:

```bash
bash scripts/03_experiments/run_create_experiment_splits.sh \
  "$PWD" "$PWD/config/experiment_daily.R" \
  --modes loo
```

Hourly cluster:

```bash
bash scripts/03_experiments/run_create_experiment_splits.sh \
  "$PWD" "$PWD/config/experiment_hourly.R" \
  --modes cluster
```

### Create several selected experiments

```bash
bash scripts/03_experiments/run_create_experiment_splits.sh \
  "$PWD" "$PWD/config/experiment_daily.R" \
  --modes allseen,loo
```

Only the explicitly selected modes are inspected and created.
Other modes are not modified, even if they contain existing results.

### Create all configured experiments

```bash
bash scripts/03_experiments/run_create_experiment_splits.sh \
  "$PWD" "$PWD/config/experiment_daily.R"
```

When `--modes` is omitted, all `experiment$split_modes` are selected.

The launcher validates the selection and destination directories before
creating the first mode. Each generated mode is then automatically
validated before proceeding to the next one.

## Output structure

Partitions are stored under:

```text
experiments/<timestep>/<mode>/<fold>/
```

For example:

```text
experiments/daily/
  allseen/
    all_basins/
      train_basins.txt
      test_basins.txt
      metadata.RData
  loo/
    fold_001/
      train_basins.txt
      test_basins.txt
      metadata.RData
  kfold/
    fold_01/
      train_basins.txt
      test_basins.txt
      metadata.RData
  cluster/
    cluster_CD/
      train_basins.txt
      test_basins.txt
      metadata.RData
```

Each fold contains:

- `train_basins.txt`: basin IDs used for emulator training.
- `test_basins.txt`: basin IDs used for testing.
- `metadata.RData`: partition type, fold name, basin assignments,
  random seed and mode-specific metadata.

Simulation, hydrograph, evaluation and summary outputs are produced
by later workflow modules.

## Validation

The launcher automatically runs `02_validate_experiment_splits.R`
after creating each selected mode.

The validator can also be run independently on existing experiments:

```bash
Rscript --vanilla \
  scripts/03_experiments/02_validate_experiment_splits.R \
  loo \
  "$PWD/config/experiment_daily.R" \
  "$PWD"
```

For `loo`, `kfold` and `cluster`, validation checks that:

- All selected basins appear exactly once across the test sets.
- Training and testing basins are disjoint in each fold.
- Training basins are the complement of test basins.
- No unknown basin is included.
- The fold structure is consistent with the selected mode.

Additional checks cover one test basin per LOO fold, approximately
balanced K-fold sizes, and complete climate-zone membership.

For `allseen`, both train and test contain all selected basins.

Run this validator before submitting existing or previously generated
experiments. Downstream simulation launchers discover existing fold
directories but do not themselves verify complete basin coverage.

## Existing experiments and --force

By default, the launcher refuses to replace a selected experiment
directory containing files.

To regenerate explicitly selected modes whose directories contain
only partition files:

```bash
bash scripts/03_experiments/run_create_experiment_splits.sh \
  "$PWD" "$PWD/config/experiment_daily.R" \
  --modes loo --force
```

`--force` requires `--modes`.

Before replacement, the launcher checks all selected destinations.
Replacement is refused if any selected mode contains scientific results,
unexpected files or additional nested directories.

Only selected split-only directories may be removed and recreated.
Other experiment modes are never touched.

`--force` is not a simulation cleanup mechanism and must not be used
to replace experiments containing emulator outputs, hydrographs,
evaluations or result summaries.

A validation error stops the launcher. The launcher is not a
transactional workflow manager and does not automatically roll back
partitions already created in an earlier selected mode.

## Direct generator interface

For individual use, the underlying generator remains available:

```bash
Rscript --vanilla \
  scripts/03_experiments/01_create_experiment_splits.R \
  kfold \
  "$PWD/config/experiment_daily.R" \
  "$PWD" \
  5
```

The generator takes:

```text
<allseen|loo|kfold|cluster> <config_file> <dirMain> [K|cluster_column]
```

The direct generator protects nonempty experiment directories, but it
does not automatically invoke the validator. Prefer the launcher for
routine creation.

## Downstream compatibility

- `04_simulations/emulator` reads fold-level train and test files.
- Local emulator simulations run on an explicitly selected fold.
- ARC and FIR submission scripts discover folds by their train/test files.
- `05_evaluation` evaluates the selected test basins.
- `06_analysis` collects test-basin results across folds.

The spatial split creation does not run FUSE or train any emulator.
