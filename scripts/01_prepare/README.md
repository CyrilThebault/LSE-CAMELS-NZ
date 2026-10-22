# CAMELS-NZ and FUSE input preparation

This directory contains the scripts used to prepare and validate the
CAMELS-NZ inputs required by the lumped FUSE emulator workflow.

For an overview of the complete workflow, see the
[repository README](../../README.md).

The observed flood-event catalogue has a separate workflow, documented
in [floods/README.md](floods/README.md).

## 1. Experiment configuration

Each repository clone corresponds to one fixed experiment.

Before running the workflow:

1. Define the selected basins in `config/basins.txt`, with one
   CAMELS-NZ `Station_ID` per line.
2. Select and configure one experiment file, for example
   `config/experiment_daily.R` or `config/experiment_hourly.R`.
3. Review `config/attributes_used.txt`.
4. Ensure that the CAMELS-NZ source data and the required FUSE files
   are available at the locations specified by the configuration.
5. Ensure that the required R packages and FUSE environment are installed.

Keep the basin selection and experiment configuration unchanged
throughout the experiment. Use a separate clone for a different
experimental setup.

All preparation scripts receive the experiment configuration explicitly.

From the repository root:

```bash
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"
```

Replace `experiment_daily.R` with `experiment_hourly.R` when preparing
an hourly experiment.

## 2. Preparation steps

The scripts should be run in the following order.

| Script | Purpose |
| --- | --- |
| `01_prepare_CAMELS_NZ.R` | Prepare forcing and elevation-band NetCDF files for the selected basins |
| `02_prepare_FUSE_settings.R` | Prepare the FUSE parameter and structural-decision files |
| `03_create_FUSE_metadata.R` | Build the FUSE metadata used by the workflow |
| `04_create_CAMELS_NZ_attributes.R` | Merge static CAMELS-NZ attributes and retain exactly the selected basins |
| `05_validate_preparation.R` | Validate the prepared inputs and report data-quality diagnostics |

### Step 1: Prepare basin-level forcing files

For a sequential run:

```bash
Rscript scripts/01_prepare/01_prepare_CAMELS_NZ.R \
  ALL "$CONFIG_FILE" "$DIR_MAIN"
```

`ALL` means all basins listed in `config/basins.txt`.

A single selected basin can also be prepared by replacing `ALL` with
its `Station_ID`. The ID must belong to `config/basins.txt`.

The script produces, for each selected basin:

```text
data/forcings/<timestep>/<ID>/<ID>_input.nc
data/forcings/<timestep>/<ID>/<ID>_elev_bands.nc
```

The input NetCDF contains precipitation, temperature, potential
evapotranspiration and observed streamflow, aligned to the experiment's
simulation period and temporal resolution.

The NetCDF time coordinate represents the midpoint of each interval,
with interval bounds stored separately.

#### Local parallel execution

The local launcher requires GNU Parallel.

```bash
export NCORES=5
bash scripts/01_prepare/01_prepare_CAMELS_NZ_local.sh
```

Adjust `NCORES` to the available resources.

#### ARC HPC

Create the Slurm log directory before submission:

```bash
mkdir -p logs/prepare

NBASINS=$(wc -l < "$DIR_MAIN/config/basins.txt")

sbatch \
  --array=1-"$NBASINS" \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/01_prepare_CAMELS_NZ_hpc_arc.slurm
```

The ARC launcher loads the required software modules and prepares
one basin per array task.

#### FIR HPC

Create the Slurm log directory before submission:

```bash
mkdir -p logs/prepare

NBASINS=$(wc -l < "$DIR_MAIN/config/basins.txt")

sbatch \
  --array=1-"$NBASINS" \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/01_prepare_CAMELS_NZ_hpc_fir.slurm
```

The FIR launcher uses its own software-module environment.

For either HPC environment, confirm that `DIR_MAIN` and `CONFIG_FILE`
refer to paths accessible from the compute nodes.

### Step 2: Prepare FUSE settings

```bash
Rscript scripts/01_prepare/02_prepare_FUSE_settings.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The source FUSE template is defined by `experiment$paths$fuse_template`
in the selected experiment configuration. In the supplied configurations,
this path is derived from `ROOT`.

The template must contain the following files under its `settings/`
directory:

- `fuse_zConstraints_snow.txt`
- `fuse_zNumerix.txt`
- `list_decision_78.txt`
- `fuse_zDecisions/fuse_zDecisions_<ID>.txt` for each ID listed in
  `list_decision_78.txt`.

The script copies the required files to `data/settings/` and
`data/zDecisions/`. It verifies the source files and refuses to
overwrite existing outputs unless `--force` is specified.

The resulting settings and structural decisions are used by the
subsequent FUSE metadata preparation step.

### Step 3: Create FUSE metadata

```bash
Rscript scripts/01_prepare/03_create_FUSE_metadata.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The script constructs the FUSE metadata from the available model
parameters and structural decisions.

Its output is:

```text
data/useful_files/fuse_settings_files.RData
```

### Step 4: Create static basin attributes

```bash
Rscript scripts/01_prepare/04_create_CAMELS_NZ_attributes.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The script merges the five CAMELS-NZ static attribute tables using
`Station_ID`.

The resulting `attributes.RData` contains exactly the basins listed
in `config/basins.txt`, in the same order.

All available static attribute columns are retained; the subset used
by the emulator is specified separately in `config/attributes_used.txt`.

Output:

```text
data/useful_files/attributes.RData
```

### Step 5: Validate preparation

For a read-only check:

```bash
Rscript scripts/01_prepare/05_validate_preparation.R \
  "$CONFIG_FILE" "$DIR_MAIN" --check
```

The validator checks:

- Presence of each basin's forcing and elevation-band files.
- Exact agreement between `attributes.RData` and `config/basins.txt`.
- NetCDF temporal units and the complete expected time axis.
- Missing values in meteorological forcings.
- Missing streamflow observations, reported diagnostically.
- Missing values in the configured emulator attributes.

Missing streamflow observations are reported but do not, by themselves,
invalidate preparation.

The `--check` option writes no reports. The command returns a nonzero
exit status if preparation validation fails.

To create the QC reports:

```bash
Rscript scripts/01_prepare/05_validate_preparation.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The generated reports are:

```text
data/useful_files/attribute_QC.csv
data/useful_files/basin_attribute_QC.csv
data/useful_files/<timestep>/preparation_report.csv
```

The attribute QC reports describe the configured attributes, while
the preparation report records the basin-level checks.

## 3. Output organization

Time-step-specific preparation outputs are stored separately:

```text
data/forcings/<timestep>/
data/useful_files/<timestep>/
```

Shared outputs include:

```text
data/settings/
data/zDecisions/
data/useful_files/fuse_settings_files.RData
data/useful_files/attributes.RData
```

The shared attribute table still depends on the fixed basin selection
of the experiment. It must not be reused with a different `basins.txt`
without regenerating and validating it.

## 4. Existing files and safe reruns

Preparation scripts protect existing output files against accidental
replacement.

Use `--force` explicitly when a supported preparation command needs
to replace existing outputs. Inspect and back up important files
before doing so.

For `05_validate_preparation.R`:

- `--check` performs read-only validation.
- Running without either option writes reports only when the output
  report files do not already exist.
- `--force` allows existing reports to be replaced.

Do not use `--force` routinely for ordinary validation.

## 5. Related documentation

- [Main workflow](../../README.md)
- [Observed flood catalogue and QC](floods/README.md)
- [Prepared testcase](../../testcase/README.md)
