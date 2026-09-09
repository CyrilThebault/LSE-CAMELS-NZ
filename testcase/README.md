# CAMELS-NZ Emulator Test Case

This directory contains a small, prepared test case for the
`LSE-CAMELS-NZ` workflow.

The purpose of this test case is to allow users to explore and run the
Large-Sample Emulator (LSE) workflow without downloading and processing the
complete CAMELS-NZ dataset or preparing the FUSE input files from a reference
FUSE template.

The test case contains five CAMELS-NZ catchments, uses FUSE structural
decision `126`, and provides prepared inputs and initial FUSE simulations at
both daily and hourly time steps.

## Contents

The directory follows the structure of the main repository:

```text
testcase/
├── config/
│   ├── attributes_used.txt
│   ├── basins.txt
│   ├── experiment.R
│   ├── daily/
│   │   └── experiment.R
│   └── hourly/
│       └── experiment.R
├── data/
│   ├── forcings/
│   │   ├── daily/
│   │   └── hourly/
│   ├── settings/
│   ├── useful_files/
│   └── zDecisions/
├── outputs/
│   ├── daily/
│   │   └── iter0/
│   └── hourly/
│       └── iter0/
└── README.md
```

### `config/`

The configuration files define the small experiment distributed with the test
case:

- `basins.txt`: catchments included in the test case;
- `attributes_used.txt`: CAMELS-NZ catchment attributes used as emulator
  predictors;
- `daily/experiment.R`: configuration for the daily experiment;
- `hourly/experiment.R`: configuration for the hourly experiment;
- `experiment.R`: active workflow configuration.

The active configuration is daily by default.

To select the daily experiment:

```bash
cp config/daily/experiment.R config/experiment.R
```

To select the hourly experiment:

```bash
cp config/hourly/experiment.R config/experiment.R
```

The experiment dates are defined explicitly in each configuration file and
should be consistent with the selected time step.

### `data/`

The data directory contains the files normally generated during the preparation
stage of the workflow:

- `forcings/daily/`: prepared daily FUSE forcing and elevation-band NetCDF
  files;
- `forcings/hourly/`: prepared hourly FUSE forcing and elevation-band NetCDF
  files;
- `settings/`: FUSE parameter-setting files shared by both time steps;
- `zDecisions/`: structural-decision files shared by both time steps;
- `useful_files/`: processed CAMELS-NZ attributes and FUSE parameter
  information required by the workflow.

### `outputs/`

Precomputed initial FUSE simulations are provided for both time steps:

```text
outputs/daily/iter0/
outputs/hourly/iter0/
```

These simulations can be used directly to train and test the emulator without
rerunning the initial FUSE parameter ensemble.

The same normalized Latin Hypercube parameter samples are used for the daily
and hourly test cases. The resulting FUSE simulations differ because the model
is driven by forcing data at different temporal resolutions.

## Using the test case

The test case is intended to be copied into the root of the main
`LSE-CAMELS-NZ` repository.

From the repository root:

```bash
cp -R testcase/config/. config/
cp -R testcase/data/. data/
cp -R testcase/outputs/. outputs/
```

The test configuration will therefore replace the corresponding configuration
files in `config/`. If you already have a working configuration, make a copy of
it before running these commands.

After copying the test case, select the temporal resolution to use.

For daily:

```bash
cp config/daily/experiment.R config/experiment.R
```

For hourly:

```bash
cp config/hourly/experiment.R config/experiment.R
```

All timestep-specific inputs, outputs, and experiments are automatically read
from or written to the corresponding `daily/` or `hourly/` directory according
to `experiment$timestep`.

## Starting from the prepared FUSE inputs

To test both the initial FUSE simulations and the emulator workflow, copy
`config/` and `data/` from the test case but do not copy `outputs/`.

From the repository root:

```bash
cp -R testcase/config/. config/
cp -R testcase/data/. data/
```

Then select either the daily or hourly configuration and start the workflow
from:

```text
scripts/02_iter0/
```

The initial FUSE ensemble will be written to:

```text
outputs/<timestep>/iter0/
```

where `<timestep>` is either `daily` or `hourly`.

## Starting directly from the emulator

If the objective is only to explore the Large-Sample Emulator, copy the
complete test case, including the precomputed `outputs/`.

The preparation and initial FUSE ensemble stages can then be skipped.

The experiment splits can be created directly, followed by the emulator
workflow.

For example, to create a 2-fold cross-validation experiment:

```bash
Rscript scripts/04_experiments/01_create_experiment_splits.R kfold "$PWD" 2
```

The resulting folds are stored separately for each temporal resolution:

```text
experiments/daily/kfold/
```

or:

```text
experiments/hourly/kfold/
```

depending on the active `config/experiment.R`.

The emulator can then be trained and evaluated using the workflow described in
the main repository README.

## Purpose of the test case

This dataset is intended for demonstration and testing only.

With only five catchments, the resulting emulator should **not** be interpreted
as a scientifically meaningful regional model. The small dataset is provided
to demonstrate the workflow, inspect its intermediate outputs, and verify that
the emulator can be trained and evaluated successfully at both daily and hourly
time steps.

For scientific experiments, users should prepare the complete set of required
CAMELS-NZ catchments following the preparation procedure described in the main
README.

## CAMELS-NZ

The test case contains a small subset of data derived from the CAMELS-NZ
dataset.

CAMELS-NZ is distributed under the Creative Commons Attribution 4.0
International (CC BY 4.0) licence.

CAMELS-NZ should be cited as:

Bushra, S., Shakya, J., Cattoën, C., Fischer, S., and Pahlow, M.:
CAMELS-NZ: hydrometeorological time series and landscape attributes for
New Zealand, Earth System Science Data, 17, 5745–5760, 2025.

https://doi.org/10.5194/essd-17-5745-2025

Dataset:

https://doi.org/10.26021/canterburynz.28827644

Licence:

https://creativecommons.org/licenses/by/4.0/

## FUSE

This workflow uses the Framework for Understanding Structural Errors (FUSE)
hydrological modelling framework.

The simulations provided with this test case were generated using the
`staging` branch of the CH-Earth FUSE implementation at commit
`55864a2c56270bba85dd4cb998ed36665e134dec`:

https://github.com/CH-Earth/fuse/tree/55864a2c56270bba85dd4cb998ed36665e134dec

FUSE is distributed under the GNU General Public License version 3
(GPL-3.0).

FUSE should be cited as:

Clark, M. P., Slater, A. G., Rupp, D. E., Woods, R. A., Vrugt, J. A.,
Gupta, H. V., Wagener, T., and Hay, L. E.:
Framework for Understanding Structural Errors (FUSE): A modular framework
to diagnose differences between hydrological models,
Water Resources Research, 44, W00B02, 2008.

https://doi.org/10.1029/2007WR006735
