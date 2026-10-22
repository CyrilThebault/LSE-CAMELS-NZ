# Observed flood catalogue and quality control

This directory contains the workflow used to detect, visualise,
quality-control, and prepare observed flood events for the
LSE-CAMELS-NZ evaluation.

For the main workflow, see the [repository README](../../../README.md).
For general CAMELS-NZ/FUSE preparation, see
[../README.md](../README.md).

## 1. Principles

The observed flood catalogue is detected once from hourly observed
discharge and is subsequently used for both hourly and daily
flood-performance analyses.

Important conventions:

- Detection uses the original hourly CAMELS-NZ streamflow CSV data,
  not the prepared FUSE forcing NetCDF files.
- The selected catchments are defined in `config/basins.txt`.
- The experiment configuration provides paths and time conventions.
- A repository clone corresponds to one fixed experiment.
- Flood events are not independently redetected at daily resolution.
- The observed catalogue is canonical: event identifiers and
  boundaries remain unchanged during quality control.
- Automated QC identifies events requiring review but does not
  automatically exclude events.
- Manual QC decisions determine which events are eligible for
  subsequent performance analysis.

The flood-detection methodology is fixed. Documentation changes must
not be interpreted as changes to event detection or segmentation.

## 2. Workflow

Run the following scripts in order:

| Script | Purpose |
| --- | --- |
| `01_build_observed_flood_catalogue.R` | Detect canonical observed floods and write diagnostics |
| `02_plot_observed_flood_catalogue.R` | Visualise canonical events or events requiring review |
| `03_screen_observed_flood_qc.R` | Screen events for potential quality problems |
| `04_finalize_observed_flood_qc.R` | Apply manual decisions and create the reviewed catalogue |
| `05_build_observed_flood_daily_units.R` | Derive daily evaluation units from eligible hourly events |

Visualisation can be repeated before or after automated QC, using
the corresponding event table.

Unless specified otherwise, commands below are executed from the
repository root.

Set the experiment paths once:

```bash
export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment_daily.R"
```

Use the configuration belonging to the current experiment clone.
For an hourly experiment, select its fixed hourly configuration
instead. Both configurations use hourly observations for flood
detection.

## 3. Build the canonical observed flood catalogue

### 3.1 Input data

The script reads the raw hourly CAMELS-NZ observed streamflow
through `read_camels_nz_hourly_qobs()` in
`scripts/functions/floods.R`.

The source data paths are resolved from the experiment
configuration and the associated CAMELS-NZ metadata.

The prepared forcing files under `data/forcings/hourly/` are
not used for flood detection.

### 3.2 Detection methodology

The fixed detection procedure is:

1. Smooth hourly observed discharge to estimate baseflow and
   quickflow.
2. Identify candidate quickflow events using `hydroEvents`.
3. Retain candidates whose aligned raw observed discharge exceeds
   the basin-specific Q99 threshold.
4. Define event fragments using a baseflow-index threshold of 0.95.
5. Consolidate BFI95 fragments where raw discharge remains above
   Q99 and the intervening minimum is at least 90% of the smaller
   neighbouring peak.
6. Merge adjacent high-flow events if discharge remains above Q99
   between them, or if the gap is at most 12 hours and the
   intervening minimum is at least 90% of the smaller peak.
7. Extend event ends, where applicable, to the beginning of the
   first period of at least 12 consecutive hourly observations
   at or below Q99 following the final retained Q99 candidate.
8. Clip extensions at the intervening minimum when another
   independent event follows in the same continuous-data block.
9. Resolve shared hourly boundaries by assigning the shared
   observation to the later event.

Event starts are retained.

Missing observations divide the record into continuous finite-data
blocks. Events are never joined across missing-data gaps, and
missing discharge is not interpolated for flood detection.

### 3.3 Run locally

Using the provided launcher:

```bash
export NCORES=4
bash scripts/01_prepare/floods/01_build_observed_flood_catalogue_local.sh
```

Alternatively, call the R script directly:

```bash
Rscript scripts/01_prepare/floods/01_build_observed_flood_catalogue.R \
  "$CONFIG_FILE" "$DIR_MAIN" 4
```

The final numeric argument specifies the number of R workers.
The local launcher uses `NCORES`, defaulting to 4.

### 3.4 Run on ARC HPC

```bash
mkdir -p logs/floods

sbatch \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/floods/01_build_observed_flood_catalogue_hpc_arc.slurm
```

### 3.5 Run on FIR HPC

```bash
mkdir -p logs/floods

sbatch \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/floods/01_build_observed_flood_catalogue_hpc_fir.slurm
```

The HPC launchers use `SLURM_CPUS_PER_TASK` as the default
number of R workers, unless `NCORES` is explicitly supplied.

### 3.6 Outputs

```text
data/flood/
  observed_flood_catalogue.csv
  diagnostics/
    observed_flood_candidates.csv
    observed_flood_excluded.csv
    observed_flood_summary.csv
```

These files are protected against replacement. The detector
refuses to run if an output already exists, unless `--force`
is explicitly supplied to the R script.

Do not regenerate the canonical catalogue during ordinary QC.

## 4. Visualise observed flood events

The visualiser produces basin-level PDF reports containing
event hydrographs and associated diagnostics.

It supports both the full canonical catalogue and the subset
of events selected for manual QC review.

### 4.1 Direct R interface

```bash
Rscript scripts/01_prepare/floods/02_plot_observed_flood_catalogue.R \
  "$CONFIG_FILE" \
  "$DIR_MAIN" \
  "$DIR_MAIN/data/flood/observed_flood_catalogue.csv" \
  "<ID>" \
  "/path/to/output.pdf"
```

Replace `<ID>` with a basin ID from the selected experiment.

### 4.2 Local parallel launcher

For all selected catchments:

```bash
NCORES=4 \
  bash scripts/01_prepare/floods/02_plot_observed_flood_catalogue_local.sh
```

For one catchment:

```bash
BASIN_IDS="$(head -n 1 config/basins.txt)" NCORES=1 \
  bash scripts/01_prepare/floods/02_plot_observed_flood_catalogue_local.sh
```

For events flagged for QC review, select the review table:

```bash
EVENTS_FILE="$DIR_MAIN/data/flood/qc/observed_flood_qc_review.csv" \
  NCORES=4 \
  bash scripts/01_prepare/floods/02_plot_observed_flood_catalogue_local.sh
```

The QC review table is generated by Step 5 below. Run that step
before requesting QC review plots.

### 4.3 ARC HPC

```bash
mkdir -p logs/floods

sbatch \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/floods/02_plot_observed_flood_catalogue_hpc_arc.slurm
```

### 4.4 FIR HPC

```bash
mkdir -p logs/floods

sbatch \
  --export=ALL,DIR_MAIN="$DIR_MAIN",CONFIG_FILE="$CONFIG_FILE" \
  scripts/01_prepare/floods/02_plot_observed_flood_catalogue_hpc_fir.slurm
```

For either HPC launcher, `EVENTS_FILE` and `BASIN_IDS` can
be supplied through the Slurm environment to select review
events or a subset of basins.

### 4.5 Plot launcher settings and outputs

The local and HPC plotting launchers support:

| Variable | Meaning |
| --- | --- |
| `DIR_MAIN` | Repository root |
| `CONFIG_FILE` | Fixed experiment configuration |
| `NCORES` | Number of parallel plotting processes |
| `BASIN_FILE` | Basin-list file; defaults to `config/basins.txt` |
| `BASIN_IDS` | Optional space- or comma-separated basin subset |
| `EVENTS_FILE` | Catalogue or QC review CSV |
| `OUT_DIR` | Optional PDF output directory |

Default PDF paths:

```text
data/flood/pdf/<ID>_observed_flood_review.pdf
data/flood/qc/pdf/<ID>_observed_flood_qc_review.pdf
```

The plotting launchers check their complete list of destination
PDFs before starting. If any selected output already exists,
the launcher stops rather than overwriting it.

The R plotting script supports `--force` for an explicit
single-file replacement, but the parallel launchers do not
automatically pass this option.

## 5. Automated observed flood QC

Run the screening script after constructing the canonical
catalogue.

```bash
NCORES=8 Rscript \
  scripts/01_prepare/floods/03_screen_observed_flood_qc.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The number of workers is controlled by `NCORES`, subject to
the available local cores.

The screening uses the canonical event table and the original
hourly observed streamflow.

It evaluates event characteristics and potential data-quality
problems using the implemented QC criteria.

QC results are diagnostic: an event flagged for review is not
automatically excluded.

Default outputs:

```text
data/flood/qc/observed_flood_qc.csv
data/flood/qc/observed_flood_qc_review.csv
```

The first CSV contains the canonical events with their screening
results. The second contains only events requiring manual review.

The `QC_OUT_DIR` environment variable may override the output
directory for this screening step.

Both outputs are protected. Existing screening files require an
explicit `--force` to be recalculated.

Do not use `--force` without checking whether the current
screening results are still needed for manual review.

## 6. Manual QC decisions

Manual review decisions are stored in:

```text
data/flood/qc/observed_flood_qc_decisions.csv
```

This file is manually maintained and must never be automatically
replaced as part of catalogue generation or QC screening.

It contains four columns:

| Column | Purpose |
| --- | --- |
| `event_id` | Exact canonical event identifier |
| `decision` | `keep` or `exclude` |
| `reason` | Required when excluding an event |
| `comment` | Optional review note |

Every event flagged for manual review must receive a decision
before finalisation.

Events not flagged for review are accepted by default. A
non-flagged event can still be excluded manually by supplying
its exact `event_id`, an `exclude` decision, and a reason.

Manual decisions do not alter event start/end times, merge
events, or create new events.

The `data/` directory is not tracked by Git in this workflow.
Back up the completed decisions file independently and preserve
it with the scientific results.

## 7. Finalise the reviewed catalogue

After completing manual review:

```bash
Rscript scripts/01_prepare/floods/04_finalize_observed_flood_qc.R \
  "$DIR_MAIN"
```

The script reads:

```text
data/flood/observed_flood_catalogue.csv
data/flood/qc/observed_flood_qc.csv
data/flood/qc/observed_flood_qc_decisions.csv
```

It requires the QC table to contain exactly the canonical event
IDs in the same order.

It also validates the manual decisions and rejects unknown
event IDs, duplicate decisions, invalid decisions, and
unresolved required reviews.

Output:

```text
data/flood/qc/observed_flood_catalogue_reviewed.csv
```

The reviewed catalogue retains canonical event IDs and
boundaries and adds review information, including
`qc_status` and `analysis_eligible`.

| `qc_status` | Interpretation | Eligible |
| --- | --- | --- |
| `auto_pass` | Not flagged for review | Yes |
| `review_keep` | Reviewed and retained | Yes |
| `review_exclude` | Reviewed and excluded | No |
| `manual_exclude` | Unflagged but manually excluded | No |
| `review_pending` | Required review incomplete | Finalisation fails |

The script does not overwrite an existing reviewed catalogue
unless `--force` is explicitly provided.

It does not overwrite the manual decisions file.

## 8. Build daily flood evaluation units

Daily evaluation units are derived from the reviewed canonical
hourly catalogue.

Only events with `analysis_eligible=TRUE` are used.

```bash
Rscript scripts/01_prepare/floods/05_build_observed_flood_daily_units.R \
  "$CONFIG_FILE" "$DIR_MAIN"
```

The script uses the experiment configuration to interpret
timestamps and daily boundaries.

It does not detect another set of daily floods or modify the
canonical hourly event identifiers and boundaries.

Default outputs:

```text
data/flood/qc/observed_flood_daily_units.csv
data/flood/qc/observed_flood_daily_event_mapping.csv
```

The output directory can be changed with the
`FLOOD_DAILY_OUTPUT_DIR` environment variable.

Existing outputs are protected unless `--force` is explicitly
passed to the R script.

## 9. Reproducibility and safe reruns

The canonical detection methodology is fixed.

To reproduce the analyses consistently:

1. Keep `config/basins.txt` and the experiment configuration
   fixed within the repository clone.
2. Preserve the original observed streamflow and input metadata.
3. Retain the canonical catalogue and its diagnostic outputs.
4. Preserve the automated QC outputs used during manual review.
5. Back up the manually curated decisions file.
6. Use `analysis_eligible` from the reviewed catalogue for
   downstream performance calculations.
7. Use the same canonical hourly events for daily and hourly
   comparisons.

Do not regenerate the catalogue simply because the emulator's
temporal resolution changes.

Use `--force` only after inspecting the existing outputs and
confirming that replacement is intended.

## 10. Related documentation

- [Main repository README](../../../README.md)
- [CAMELS-NZ/FUSE preparation](../README.md)
- [Prepared testcase](../../../testcase/README.md)
