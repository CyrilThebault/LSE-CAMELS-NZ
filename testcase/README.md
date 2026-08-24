# CAMELS-NZ Emulator Test Case

This directory contains a small, prepared test case for the
`EmulatorForLumpedFUSE_CAMELS-NZ` workflow.

The purpose of this test case is to allow users to explore and run the
Large-Sample Emulator (LSE) workflow without downloading and processing the
complete CAMELS-NZ dataset or preparing the FUSE input files from a reference
FUSE template.

The test case contains five CAMELS-NZ catchments and uses FUSE structural
decision `126`.

## Contents

The directory follows the structure of the main repository:

```text
testcase/
├── config/
│   ├── attributes_used.txt
│   ├── basins.txt
│   └── experiment.R
├── data/
│   ├── forcings/
│   ├── settings/
│   ├── useful_files/
│   └── zDecisions/
├── outputs/
│   └── iter0/
└── README.md
```

### `config/`

The configuration files define the small experiment distributed with the test
case:

- `basins.txt`: catchments included in the test case;
- `attributes_used.txt`: CAMELS-NZ catchment attributes used as emulator
  predictors;
- `experiment.R`: workflow configuration used for the test case.

### `data/`

The data directory contains the files normally generated during the preparation
stage of the workflow:

- `forcings/`: prepared daily FUSE forcing and elevation-band NetCDF files;
- `settings/`: FUSE control and parameter-setting files;
- `zDecisions/`: structural-decision file required for zDecision 126;
- `useful_files/`: processed CAMELS-NZ attributes and FUSE parameter
  information required by the workflow.

### `outputs/iter0/`

Precomputed initial FUSE simulations are also provided for the five catchments.

These simulations can be used directly to train and test the emulator without
rerunning the initial FUSE parameter ensemble.

## Using the test case

The test case is intended to be copied into the root of the main
`EmulatorForLumpedFUSE_CAMELS-NZ` repository.

From the repository root:

```bash
cp -R testcase/config/. config/
cp -R testcase/data/. data/
cp -R testcase/outputs/. outputs/
```

The test configuration will therefore replace the corresponding configuration
files in `config/`. If you already have a working configuration, make a copy of
it before running these commands.

## Starting from the prepared FUSE inputs

To test both the initial FUSE simulations and the emulator workflow, copy
`config/` and `data/` from the test case but do not copy `outputs/iter0/`.

The CAMELS-NZ and FUSE preparation steps can then be skipped.

Start the workflow from:

```text
scripts/02_iter0/
```

This will generate a new initial FUSE ensemble for the five test catchments.

## Starting directly from the emulator

If the objective is only to explore the Large-Sample Emulator, copy the complete
test case, including `outputs/iter0/`.

The following stages can then be skipped:

```text
scripts/01_preparation/
scripts/02_iter0/
```

The experiment splits can be created directly, followed by the emulator
workflow.

For example, to create a 2-fold cross-validation experiment:

```bash
Rscript scripts/04_experiments/01_create_experiment_splits.R kfold "$PWD" 2
```

The resulting folds will be created under:

```text
experiments/kfold/
```

The emulator can then be trained and evaluated using the workflow described in
the main repository README.

## Purpose of the test case

This dataset is intended for demonstration and testing only.

With only five catchments, the resulting emulator should **not** be interpreted
as a scientifically meaningful regional model. The small dataset is provided
to demonstrate the workflow, inspect its intermediate outputs, and verify that
the emulator can be trained and evaluated successfully.

For scientific experiments, users should prepare the complete set of required
CAMELS-NZ catchments following the preparation procedure described in the main
README.

## Data and licence

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
