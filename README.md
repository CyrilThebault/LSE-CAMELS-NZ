# CAMELS-NZ lumped Large-Sample Emulator workflow

This repository adapts the [Emulators](https://github.com/nvasquez-plac/Emulators)
framework developed by the Emulator Development Working Group at the University
of Calgary to a lumped CAMELS-NZ workflow supporting both daily and hourly time
steps.

A small prepared testcase is available under `testcase/` for users who want to
explore the emulator without downloading and processing the complete CAMELS-NZ
dataset or preparing a full FUSE template.

## 0. Setup

1. Copy `config/basins.txt.example` to `config/basins.txt` and fill it with the
   study basins. The file must contain one CAMELS-NZ `Station_ID` per line,
   with no header, additional columns, empty lines, or duplicate IDs.

2. Review the experiment configurations under:

   ```text
   config/daily/experiment.R
   config/hourly/experiment.R
   ```

   The active workflow configuration is:

   ```text
   config/experiment.R
   ```

   To select the daily experiment:

   ```bash
   cp config/daily/experiment.R config/experiment.R
   ```

   To select the hourly experiment:

   ```bash
   cp config/hourly/experiment.R config/experiment.R
   ```

   Edit the selected configuration to match your objectives. Experiment dates
   are defined explicitly and should be consistent with the selected time step.

   `ROOT` can be supplied as an environment variable.

3. Review `config/attributes_used.txt`.

4. Make sure you are in the repository root:

   ```text
   /your/path/LSE-CAMELS-NZ
   ```

5. Prepare your working environment by compiling the FUSE `staging` branch
   at the commit documented in the [FUSE](#fuse) section below (see
   https://ch-earth-fuse.readthedocs.io/en/staging/install/install_fuse/).

6. Check the required R packages:

   ```bash
   Rscript scripts/00_check_packages.R
   ```

7. On ARC HPC, create the workflow log directories before submitting jobs:

   ```bash
   mkdir -p logs/prepare logs/iter0 logs/emulator
   ```

### ARC HPC environment

On ARC, the following modules are used:

```bash
. /work/comphyd_lab/local/modules/spack/2024v5/lmod-init-bash

module purge
module unuse $MODULEPATH
module use /work/comphyd_lab/local/modules/spack/2024v5/modules/linux-rocky8-x86_64/Core/

module load gcc/14.2.0
module load cmake/3.30.2
module load hdf5/1.14.3
module load netcdf-c/4.9.2
module load netcdf-fortran/4.6.1
module load r/4.4.1
```

The provided ARC Slurm scripts load this environment automatically.

### Time-step-specific directories

The active temporal resolution is defined by `experiment$timestep` in
`config/experiment.R`.

Time-step-specific inputs and outputs are automatically separated into:

```text
data/forcings/<timestep>/
data/useful_files/<timestep>/
outputs/<timestep>/iter0/
experiments/<timestep>/
```

where `<timestep>` is either `daily` or `hourly`.

Files that are independent of the temporal resolution remain shared, including:

```text
data/settings/
data/zDecisions/
data/useful_files/attributes.RData
data/useful_files/fuse_settings_files.RData
```

### Using the prepared testcase

The `testcase/` directory contains a small five-catchment example with prepared
daily and hourly FUSE inputs, configuration files, and precomputed iter0
results.

See `testcase/README.md` for detailed instructions.

Depending on what you want to test:

- copy the testcase `config/` and `data/` directories and start from **Step 2**
  to rerun the initial FUSE ensemble;
- copy the testcase `config/`, `data/`, and `outputs/` directories and start
  from **Step 3** to test the emulator workflow directly.

After copying the testcase, select either the daily or hourly configuration
before running the workflow.

## 1. Prepare CAMELS-NZ/FUSE inputs

Select the required temporal resolution in `config/experiment.R` before running
the preparation workflow.

The CAMELS-NZ forcing and elevation-band files are prepared independently for
each basin.

### On ARC HPC (University of Calgary)

The provided Slurm script uses a job array to prepare basins independently on
ARC. The number of array tasks is determined from `config/basins.txt`.

```bash
export DIR_MAIN="$PWD"

NBASINS=$(wc -l < "$DIR_MAIN/config/basins.txt")

sbatch \
  --array=1-"$NBASINS" \
  --export=ALL,DIR_MAIN="$DIR_MAIN" \
  scripts/01_prepare/01_prepare_CAMELS_NZ_hpc_arc.slurm
```

### On a local machine

A local shell script is provided to parallelize the input data preprocessing
step without Slurm. It uses GNU Parallel to prepare multiple basins
simultaneously across multiple cores. For example, on macOS GNU Parallel can be
installed with Homebrew:

```bash
brew install parallel
```

Then, the step can be run with:

```bash
export DIR_MAIN="$PWD"
export NCORES=5

bash scripts/01_prepare/01_prepare_CAMELS_NZ_local.sh
```

The number of parallel workers can be changed through `NCORES` depending on the
available hardware.

For a sequential run, the preparation script can also be called directly:

```bash
Rscript scripts/01_prepare/01_prepare_CAMELS_NZ.R ALL "$PWD"
```

Prepared forcing and elevation-band files are written to:

```text
data/forcings/<timestep>/
```

### Complete input preparation

Once the basin-level preparation is complete, generate the shared FUSE settings,
metadata, CAMELS-NZ attributes, and validate the prepared inputs:

```bash
Rscript scripts/01_prepare/02_prepare_FUSE_settings.R "$PWD"
Rscript scripts/01_prepare/03_create_FUSE_metadata.R "$PWD"
Rscript scripts/01_prepare/04_create_CAMELS_NZ_attributes.R "$PWD"
Rscript scripts/01_prepare/05_validate_preparation.R "$PWD"
```

The preparation report is written to:

```text
data/useful_files/<timestep>/preparation_report.csv
```

Shared FUSE metadata and CAMELS-NZ attribute information remain under:

```text
data/useful_files/
```

This step can be skipped when using the prepared testcase.

## 2. Generate immutable iter0 database

The size of the initial parameter ensemble is defined by `nIter0` in
`config/experiment.R`.

The normalized Latin Hypercube parameter design depends on the experiment seed,
basin ID, number of iterations, and active FUSE parameter set. The temporal
resolution does not directly enter the sampling procedure.

The resulting FUSE simulations are stored separately for each temporal
resolution under:

```text
outputs/<timestep>/iter0/
```

### On ARC HPC (University of Calgary)

The provided Slurm script uses a job array to run the initial FUSE ensemble
independently for each basin on ARC. The number of array tasks is determined
from `config/basins.txt`.

```bash
export DIR_MAIN="$PWD"

NBASINS=$(wc -l < "$DIR_MAIN/config/basins.txt")

sbatch \
  --array=1-"$NBASINS" \
  --export=ALL,DIR_MAIN="$DIR_MAIN" \
  scripts/02_iter0/run_iter0_hpc_arc.slurm
```

### On a local machine

A local shell script using GNU Parallel is also provided for running iter0
without Slurm.

```bash
export DIR_MAIN="$PWD"
export NCORES=5

bash scripts/02_iter0/run_iter0_local.sh
```

The number of parallel workers can be changed through `NCORES` depending on the
available hardware.

This step can be skipped when using the precomputed
`outputs/<timestep>/iter0/` distributed with the testcase.

## 3. Create experiment splits

Experiment directories are created under the active temporal resolution:

```text
experiments/<timestep>/
```

For example:

```bash
Rscript scripts/04_experiments/01_create_experiment_splits.R upper_bound "$PWD"
Rscript scripts/04_experiments/01_create_experiment_splits.R loo "$PWD"
Rscript scripts/04_experiments/01_create_experiment_splits.R kfold "$PWD" 2
```

Available experiment modes are:

- `upper_bound`: all basins are used for training and final evaluation;
- `loo`: each basin is held out once;
- `kfold`: basins are randomly divided into K folds.

For example, with the daily configuration active, a 2-fold experiment is
created under:

```text
experiments/daily/kfold/
```

With the hourly configuration active, it is created under:

```text
experiments/hourly/kfold/
```

Cluster-based cross-validation is planned but is not currently implemented.

## 4. Run one fold

The fold workflow trains on `train_basins.txt` and refines the emulator only
with those training basins. The current emulator is evaluated on
`test_basins.txt` after the initial fit (step 0) and after each refinement step
by searching the parameter space and running FUSE.

Test-basin FUSE results are used only for evaluation and never feed back into
model training.

Make sure that `config/experiment.R` corresponds to the same temporal
resolution as the experiment directory being run.

### On ARC HPC (University of Calgary)

The provided Slurm script is configured for ARC HPC. As for the iter0 script,
it can be adapted to other Slurm-based systems by modifying the HPC-specific
configuration.

For a daily experiment:

```bash
export DIR_MAIN="$PWD"
export EXPERIMENT_DIR="$PWD/experiments/daily/kfold/fold_01"
export ZDECISION=126
export NREFINE=2

sbatch scripts/03_emulator/run_LSE_fold_hpc_arc.slurm
```

For an hourly experiment, use the corresponding hourly experiment directory:

```bash
export DIR_MAIN="$PWD"
export EXPERIMENT_DIR="$PWD/experiments/hourly/kfold/fold_01"
export ZDECISION=126
export NREFINE=2

sbatch scripts/03_emulator/run_LSE_fold_hpc_arc.slurm
```

### On a local machine

The equivalent workflow can be run locally with GNU Parallel.

For example, for a daily experiment:

```bash
export DIR_MAIN="$PWD"
export EXPERIMENT_DIR="$PWD/experiments/daily/kfold/fold_01"
export ZDECISION=126
export NREFINE=2
export NCORES=4

bash scripts/03_emulator/run_LSE_fold_local.sh
```

For an hourly experiment, set:

```bash
export EXPERIMENT_DIR="$PWD/experiments/hourly/kfold/fold_01"
```

before running the same script.

## 5. Collect results

Results are collected separately for each temporal resolution.

For daily:

```bash
Rscript scripts/05_analysis/01_collect_results.R \
  "$PWD/experiments/daily/kfold" \
  126 \
  "$PWD"
```

For hourly:

```bash
Rscript scripts/05_analysis/01_collect_results.R \
  "$PWD/experiments/hourly/kfold" \
  126 \
  "$PWD"
```

The resulting `results_summary.csv` is written inside the corresponding
experiment directory. It contains one selected candidate per fold, test basin,
emulator, and refinement step.

## 6. Plot k-fold performance

After collecting the results, k-fold performance figures can be generated with:

```bash
Rscript scripts/05_analysis/02_plot_kfold_performance.R \
  "$PWD/experiments/daily/kfold" \
  "$PWD"
```

or, for the hourly experiment:

```bash
Rscript scripts/05_analysis/02_plot_kfold_performance.R \
  "$PWD/experiments/hourly/kfold" \
  "$PWD"
```

The standard k-fold performance figures and `kfold_performance_summary.csv`
summarize the final refinement step. Performance across all available
refinement steps is additionally written to
`kfold_performance_by_step.csv` and visualized in
`05_kgee_by_refinement_step`.

## Important implementation notes

- `outputs/<timestep>/iter0/` is shared by all experiments at a given temporal
  resolution and should not be regenerated for individual cross-validation
  experiments.

- Daily and hourly iter0 databases are stored separately, even when they use
  the same normalized parameter samples, because the corresponding FUSE
  simulations use forcing data at different temporal resolutions.

- Experiment-specific models, candidate sets, and FUSE results are stored under
  `experiments/<timestep>/<experiment>/<fold>/outputs/`.

- Daily and hourly experiments can coexist in the same repository without
  overwriting their forcing data, iter0 simulations, or experiment results.

- `data/settings/`, `data/zDecisions/`, CAMELS-NZ attributes, and FUSE parameter
  metadata are shared between temporal resolutions.

- Categorical attribute levels are defined from the complete CAMELS-NZ
  attribute database so that valid categories absent from an individual
  training fold remain usable for held-out basins.

- The same numerical design-matrix recipe is stored with the emulator and
  reused during prediction.

- For the upper-bound experiment, the same basins appear in train and test
  lists; test evaluations are still kept separate from emulator training for
  consistent result collection.

## CAMELS-NZ

This workflow uses data from the CAMELS-NZ dataset. The prepared test case
contains a small subset of the CAMELS-NZ data distributed with this repository.

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

The workflow was developed and tested using the `staging` branch of the
CH-Earth FUSE implementation at commit
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
