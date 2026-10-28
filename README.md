# CAMELS-NZ Large-Sample Emulator workflow

This repository supports the development and evaluation of Large-Sample
Emulators (LSE) for lumped FUSE hydrological simulations across
CAMELS-NZ catchments.

The project investigates the performance of emulators operating at
daily and hourly temporal resolutions, including their ability to
reproduce continuous streamflow and flood-event characteristics.

It also examines spatial generalization across catchments and compares
regionalized emulator predictions with locally calibrated FUSE models.

The workflow is organized into independent, reproducible modules.
This README introduces the overall structure. Each module has its own
documentation with detailed requirements, commands, outputs and
validation procedures.

## Repository organization

| Directory | Purpose |
| --- | --- |
| `config/` | Experiment configurations and basin selection |
| `data/` | Hydrological inputs, catchment information and observed flood data |
| `outputs/` | Initial simulation results and supporting outputs |
| `experiments/` | Spatial experiments, archived simulations and evaluations |
| `scripts/01_prepare/` | Preparation and validation of model inputs |
| `scripts/02_iter0/` | Initial FUSE parameter ensemble |
| `scripts/03_experiments/` | Spatial experiment partitions |
| `scripts/04_simulations/` | Emulator simulations and local calibration |
| `scripts/05_evaluation/` | Evaluation of archived FUSE hydrographs |
| `scripts/06_analysis/` | Scientific analysis and comparison of evaluation results |

Daily and hourly experiments use separate configurations:

- `config/experiment_daily.R`
- `config/experiment_hourly.R`

Their inputs and results are organized by temporal resolution.

## Workflow overview

### 1. Prepare hydrological inputs

The preparation module creates and validates the CAMELS-NZ inputs,
FUSE settings and supporting data required by subsequent simulations.

Observed flood events are prepared and quality-controlled through a
dedicated workflow. The reviewed hourly catalogue and its derived
daily evaluation units provide a common observational reference for
flood evaluation.

Documentation:

- [Input preparation](scripts/01_prepare/README.md)
- [Observed flood catalogue](scripts/01_prepare/floods/README.md)

### 2. Generate the initial FUSE ensemble

The `iter0` module samples the FUSE parameter space, runs the initial
simulations and produces the database used to train the emulators.

This stage belongs to the emulator workflow and is independent of
local SCE calibration.

Documentation:

- [Initial FUSE ensemble](scripts/02_iter0/README.md)

### 3. Define spatial experiments

The experiment module creates and validates the spatial partitions
used to evaluate emulator generalization.

Supported strategies include:

- `allseen`
- `loo` (leave-one-out)
- `kfold`
- `cluster` (climate-zone-based partitioning)

Spatial train/test partitions are distinct from the temporal
calibration/evaluation periods used for hydrological metrics.

Documentation:

- [Spatial experiment splits](scripts/03_experiments/README.md)

### 4. Produce archived FUSE simulations

Two simulation branches are available.

**Large-Sample Emulators**

Emulators are trained using the initial FUSE database and refined
through successive training and candidate-evaluation steps.

Selected parameter sets are reproduced with FUSE and their
hydrographs are archived for evaluation.

**Local calibration**

Each catchment is calibrated independently using FUSE SCE.
The optimized parameter set is reproduced and archived.

Local calibration does not depend on the emulator training workflow
or spatial train/test partitions.

Documentation:

- [Emulator simulations](scripts/04_simulations/emulator/README.md)
- [Local FUSE calibration](scripts/04_simulations/local_calibration/README.md)

### 5. Evaluate archived simulations

The evaluation module calculates continuous streamflow and flood
performance from archived FUSE hydrographs.

Continuous evaluation includes NSE and KGE (2009 formulation).

Flood evaluation includes:

- Relative error in peak discharge.
- Relative error in event volume.
- Timing difference between simulated and observed peaks.

Metrics are evaluated separately over the temporal calibration and
evaluation periods.

Daily simulations are evaluated against the original daily
CAMELS-NZ observations.

Hourly simulations are evaluated at their native resolution and
also after aggregation to daily discharge, using the original
daily observations.

The main daily/hourly comparison is therefore performed at a
common daily resolution. Native hourly evaluation provides
complementary information.

Observed flood events are not redetected during model evaluation.
The reviewed hourly catalogue and its daily evaluation units are
used throughout.

The evaluator operates on existing hydrographs and never runs FUSE.

Documentation:

- [FUSE evaluation](scripts/05_evaluation/README.md)

### 6. Analyze model performance

The analysis stage brings together evaluation results from the
different experiments, catchments and methods.

Its principal objectives are to:

- Verify the coverage and provenance of evaluation results.
- Compare methods on consistent catchment populations.
- Match daily and hourly simulations on common valid calendar days
  when comparing continuous performance.
- Match flood evaluations using the same valid daily flood units.
- Summarize differences between emulators, spatial strategies and
  local calibration.

Continuous metrics may require recalculation on common daily
observations to ensure strictly paired comparisons.

Flood metrics already computed by the evaluation module are reused
rather than independently recalculated.

This analysis module is being structured around these requirements.
Earlier experimental analysis scripts are retained under
`scripts/06_analysis/legacy/` for reference.

## Scientific comparison principles

### Daily versus hourly

The primary comparison uses daily discharge for both model
resolutions:

- Native daily FUSE simulations.
- Hourly FUSE simulations aggregated to complete calendar days.

Both are assessed against the original CAMELS-NZ daily observations.

The same calendar days must be used when drawing paired conclusions
about continuous performance.

### Flood events

The reviewed observed flood catalogue defines the events.

Daily comparisons use the same observed daily flood units across
methods, with explicit checks for valid and complete evaluation
windows.

Peak magnitude, event volume and peak timing are assessed using the
metrics produced by the evaluation module.

Native hourly flood performance is examined separately.

### Spatial generalization

Emulator predictions are evaluated on the appropriate test basins
for each spatial strategy.

Results from different folds must be combined without duplicating
catchments within a method.

Local calibration provides a basin-specific reference rather than
a spatially regionalized prediction.

### Reproducibility

The workflow uses explicit experiment configurations, validated
spatial partitions and archived simulation metadata.

Individual modules provide validation or check modes where
appropriate. Existing scientific results are not silently replaced.

For execution instructions, required software and output details,
consult the README of the relevant module.

## Figures and manuscript outputs

Scientific analysis tables are kept separate from presentation and
plotting code.

Manuscript figures and supplementary visualizations will be
developed in a dedicated plotting stage after the analysis
requirements and results are established.
