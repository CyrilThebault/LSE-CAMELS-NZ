# Evaluation of archived FUSE simulations

This module evaluates archived FUSE hydrographs from the LSE-CAMELS-NZ
experiments. It computes continuous streamflow performance metrics and
flood-event metrics for the temporal calibration and evaluation periods.

Evaluations can be performed for individual hydrographs or for all
selected hydrographs in an experiment directory.

The evaluation workflow uses existing simulation archives. It does not
run FUSE, optimize parameters, reproduce missing hydrographs, or detect
new observed flood events.

## Evaluation framework

The project runs FUSE at two temporal resolutions:

- **Daily:** one simulated discharge value per day.
- **Hourly:** one simulated discharge value per hour.

Both resolutions are evaluated against observations at their native
resolution. Hourly simulations are additionally aggregated to daily
resolution and evaluated against the original daily CAMELS-NZ
observations.

Continuous metrics and flood metrics are calculated independently for
the temporal calibration and evaluation periods.

The temporal calibration/evaluation split is distinct from the spatial
train/test partition used in emulator experiments.

### Continuous streamflow metrics

Continuous performance is calculated by aligning simulated and observed
discharge by timestamp and retaining valid observation-simulation pairs.

The global evaluation files contain:

- Nash-Sutcliffe Efficiency (NSE).
- Kling-Gupta Efficiency (KGE, 2009 formulation).
- KGE components: variability ratio (`alpha`), bias ratio (`beta`),
  and Pearson correlation (`r`).

Each file contains one result for the calibration period and one for the
evaluation period.

KGElog is not calculated by this evaluation module.

### Flood-event metrics

Flood performance is evaluated using the observed flood catalogue and
its quality-control products.

The workflow uses:

- `data/flood/qc/observed_flood_catalogue_reviewed.csv`
  for eligible observed hourly flood events.
- `data/flood/qc/observed_flood_daily_units.csv`
  for daily flood evaluation units.

Hourly flood evaluation uses the eligible hourly events from the
reviewed catalogue.

Daily flood evaluation uses the corresponding daily units, which
represent the daily projection of the observed hourly catalogue.

Flood events are not redetected from model simulations.

An event or daily unit must satisfy the relevant temporal coverage and
data-completeness requirements to receive valid metrics. The evaluation
outputs retain validity information.

## Daily and hourly evaluation

### Daily FUSE simulations

Daily simulations are evaluated using the original CAMELS-NZ daily
observed discharge series.

The evaluator produces:

| File | Description |
|---|---|
| `global_native.csv` | Continuous daily performance |
| `flood_native.csv` | Flood performance on daily evaluation units |
| `metadata.rds` | Evaluation provenance and configuration |

### Hourly FUSE simulations

Hourly simulations receive two complementary evaluations.

**Native hourly evaluation**

Simulated hourly discharge is compared with observed hourly discharge.

This produces:

- `global_native.csv`: continuous hourly performance.
- `flood_native.csv`: flood performance on eligible hourly events.

**Daily evaluation**

Hourly simulated discharge is aggregated to daily discharge.

A daily simulated value is retained only when the corresponding
calendar day contains all 24 expected hourly values, from 00:30 to
23:30, with finite simulated discharge.

Hourly discharge in mm/h is summed over the 24 hourly intervals to
obtain daily discharge in mm/day.

The aggregated simulations are paired with the original daily
CAMELS-NZ observations, rather than daily values reconstructed from
the hourly observed series.

This produces:

- `global_daily.csv`: continuous daily performance.
- `flood_daily.csv`: flood performance on daily evaluation units.

Hourly evaluations also produce `metadata.rds`.

### Comparing daily and hourly simulations

The main cross-resolution comparison uses:

- `global_native.csv` from daily FUSE simulations.
- `global_daily.csv` from hourly FUSE simulations.

For floods, the corresponding comparison uses:

- `flood_native.csv` from daily FUSE simulations.
- `flood_daily.csv` from hourly FUSE simulations.

Native hourly results provide additional information about hourly
performance; they should not be compared directly with daily metrics
as though the temporal resolutions were identical.

Using the same daily observation dataset does not guarantee identical
valid evaluation dates across simulations. Missing simulated values,
incomplete hourly days, or differences in archived simulation coverage
can produce different evaluation samples.

Strictly paired comparisons must therefore identify and use the common
valid calendar days, or otherwise explicitly account for differences
in sample coverage during analysis.

The individual evaluator computes metrics for each archived simulation
independently. It does not impose a common-day mask across different
models or temporal resolutions.

## Temporal evaluation periods

Calibration and evaluation periods are defined in the unified
`config/experiment.R` and resolved for the selected `daily` or `hourly`
timestep. The individual evaluator obtains this timestep from the archived
simulation metadata; the campaign evaluator requires `--timestep` explicitly.

The evaluation uses the experiment's configured starting date and
includes the complete calendar day of each configured ending date.

The effective end of each evaluation period is therefore 23:59:59 in
the experiment timezone.

This convention applies to continuous metrics and flood metrics at
both temporal resolutions.

The convention is identified in the evaluation metadata as:

`complete_calendar_days_v1`

The `metric_periods` metadata field records the effective evaluation
bounds. The original experiment period fields are also retained for
provenance.

The underlying experiment configurations and FUSE simulation periods
are not altered by this evaluation convention.

Calendar boundaries alone do not guarantee complete observational or
simulated data coverage. Data validity and event-completeness checks
remain applicable.

## Archived simulation inputs

The evaluator requires an existing hydrograph directory containing:

- `qSim_selected.rds`: archived simulated discharge.
- `metadata.rds`: simulation provenance.

The metadata identifies the experiment, configuration, basin,
parameter-decision structure, and selection method.

### Emulator experiments

Supported emulator methods are defined by the experiment
configuration, including RF, GBMv01, and GBMv02.

For emulator experiments, the campaign evaluator:

1. Selects spatial test basins.
2. Uses the final configured refinement step by default.
3. Requires one selected hydrograph per expected basin-emulator
   combination.
4. Validates archive metadata and directory structure.

The hydrograph is produced upstream from the unique rank-1 candidate
for its emulator, basin, phase, and model step.

The rank is determined by predicted emulator performance (`eNKGE`),
not by observed FUSE calibration or evaluation KGE.

The simulation reproduction workflow verifies the selected candidate
and its archived FUSE performance before saving the hydrograph.

The evaluation module uses the resulting archived simulation; it
does not repeat candidate selection.

### Local calibration

Local calibration uses the optimal FUSE parameter set obtained through
the SCE calibration procedure for each basin.

Unlike emulator experiments:

- There is no spatial train/test partition.
- There is no emulator refinement step.
- Parameter optimization uses the temporal calibration period.

The evaluation period remains independent of the period used for
parameter optimization.

Local calibration results are identified by method `sce`.

## Running evaluations

The evaluators use archived FUSE hydrographs and do not run FUSE or
generate missing simulations. Each archive must contain compatible
simulation metadata and reference a valid experiment configuration.

The commands below use paths relative to `DIR_MAIN`. Each example
requires the corresponding simulation archive to be available and
compatible with the selected experiment.

`--check` performs the complete evaluation without writing persistent
results. Without `--check` or `--force`, existing evaluation results are
protected against replacement. `--force` permits deliberate replacement
of evaluation outputs but does not bypass metadata validation.

### Evaluate one archived hydrograph

`01_evaluate_FUSE.R` accepts a hydrograph directory and the repository
root. The directory must contain `qSim_selected.rds` and `metadata.rds`.
The timestep and configuration are obtained from the archived metadata.

Example for a daily locally calibrated FUSE simulation:

```bash
cd "$(git rev-parse --show-toplevel)"
export DIR_MAIN="$PWD"

HYDROGRAPH_DIR="$DIR_MAIN/experiments/daily/localcalib/all_basins/hydrographs/zDecision_126/1009213/sce"

Rscript --vanilla "$DIR_MAIN/scripts/05_evaluation/01_evaluate_FUSE.R" "$HYDROGRAPH_DIR" "$DIR_MAIN" --check
```

The individual evaluator validates the archived simulation identity,
configuration and input data before calculating streamflow and flood
metrics.

### Evaluate an experiment

`02_evaluate_experiment.R` processes the selected archived simulations
of an experiment. It takes the experiment directory, the unified
configuration, the repository root and a mandatory timestep.

Example for a daily k-fold experiment:

```bash
cd "$(git rev-parse --show-toplevel)"
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment.R"

EXPERIMENT_DIR="$DIR_MAIN/experiments/daily/kfold/fold_01"

Rscript --vanilla "$DIR_MAIN/scripts/05_evaluation/02_evaluate_experiment.R" "$EXPERIMENT_DIR" "$CONFIG_FILE" "$DIR_MAIN" --timestep daily --check
```

Example for an hourly k-fold experiment:

```bash
cd "$(git rev-parse --show-toplevel)"
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment.R"

EXPERIMENT_DIR="$DIR_MAIN/experiments/hourly/kfold/fold_01"

Rscript --vanilla "$DIR_MAIN/scripts/05_evaluation/02_evaluate_experiment.R" "$EXPERIMENT_DIR" "$CONFIG_FILE" "$DIR_MAIN" --timestep hourly --check
```

The experiment evaluator checks the selected basins, methods,
hydrograph availability and metadata consistency. Missing simulations
must be generated by the upstream simulation workflow.

By default, emulator experiments use the final configured refinement
step and the selected test simulations. The optional `--step N` selects
another available emulator refinement step; it does not apply to local
calibration.

`--check` and `--force` cannot be combined.

## Output organization

Evaluation results are stored inside the experiment directory, under
`evaluation/`, following the organization of the archived hydrographs.

For emulator experiments:

```text
<experiment_dir>/
  hydrographs/
    zDecision_<id>/
      test/
        <basinID>/
          step_<N>/
            <emulator>/
              qSim_selected.rds
              metadata.rds
  evaluation/
    zDecision_<id>/
      test/
        <basinID>/
          step_<N>/
            <emulator>/
              global_native.csv
              flood_native.csv
              global_daily.csv
              flood_daily.csv
              metadata.rds
```

`global_daily.csv` and `flood_daily.csv` are present for hourly
simulations; daily simulations use their native daily outputs.

For local calibration, the method directory is organized under
`zDecision_<id>/<basinID>/sce/`, without a spatial phase or refinement
step.

The evaluation metadata records source archive paths, basin and
method identifiers, temporal resolution, experiment configuration,
and evaluation periods.

## Existing results and reproducibility

The campaign runner preserves completed evaluations by default.

Before reusing an existing result, it checks that:

- The expected files are present.
- The archived evaluation metadata identifies the expected source
  simulation and experiment.
- The evaluation uses the required temporal convention
  (`complete_calendar_days_v1`).

An evaluation with missing or incompatible temporal-convention
metadata is not silently reused.

Incomplete, unexpected, or inconsistent evaluation outputs cause an
error and require investigation.

To intentionally replace an existing evaluation, use `--force` after
reviewing the destination and its provenance.

Result publication is staged before the evaluation directory is
published, avoiding the normal exposure of partially written output
sets.

The evaluation workflow never modifies the archived FUSE hydrograph.

## Interpreting experiment results

For k-fold, leave-one-out, and climate-cluster experiments, spatial
generalization is assessed using the test-basin results collected
across the corresponding experiment partitions.

Regionalized results should be assembled with each basin represented
once per method.

For allseen experiments, test-phase results do not necessarily measure
generalization to basins that were unseen during emulator training.

For local calibration, performance reflects basin-specific parameter
optimization, rather than parameter transfer from other basins.

The temporal calibration and evaluation metrics have different
interpretations from the spatial train/test split. They must be kept
distinct when comparing strategies.

This module creates per-simulation evaluation results. Cross-method,
cross-fold, and cross-resolution comparisons are performed in the
subsequent analysis workflow.
