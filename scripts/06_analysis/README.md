# Analysis of archived FUSE evaluations

This module collects, validates and compares evaluation results produced by
`scripts/05_evaluation/`. It supports comparisons between FUSE simulations
at daily and hourly resolutions and across spatial experiment strategies.

`06_analysis` does not run FUSE, recalibrate models, redetect observed flood
events, or generate manuscript figures. Plotting belongs to a separate
`07_plots` stage.

## Workflow and responsibilities

Run the scripts in this order:

1. `01_collect_evaluations.R` inventories available evaluation archives and
   consolidates their metrics without recalculating them.
2. `02_pair_floods.R` pairs previously evaluated daily flood units and
   summarizes their existing errors. It does not recalculate flood metrics.
3. `03_compare_paired_daily.R` compares continuous daily NSE and KGE (2009)
   using strictly common valid days. It reuses archived metrics whenever
   their original valid-day coverage matches the paired coverage.

The inventory may be incomplete: missing evaluations are recorded in the
manifest and coverage summaries, rather than silently treated as complete.
The comparison scripts require at least one complete daily/hourly pair.

## Inputs and supported experiments

- The unified campaign configuration is `config/experiment.R`.
- Evaluation inputs are the archived `metadata.rds`, `global_native.csv`,
  `global_daily.csv`, `flood_native.csv` and `flood_daily.csv` outputs of
  `05_evaluation`, as applicable to the simulation timestep.
- `03_compare_paired_daily.R` also reads the archived `qSim_selected.rds`
  hydrographs and the original CAMELS-NZ daily `q_obs` NetCDF inputs.
- The inventory covers `localcalib`, `allseen`, `loo`, `kfold` and `cluster`.
  Emulator methods are `RF`, `GBMv01` and `GBMv02`; local calibration uses
  `sce` and the `all_basins` unit, without a refinement step or spatial
  `test` phase.

The daily/hourly pairs must have compatible evaluation metadata, temporal
periods and `complete_calendar_days_v1` period rules.

The continuous comparator requires both metadata records to refer to the
same existing canonical `config/experiment.R` within the selected repository.
It does not automatically substitute or rebase configuration paths.
An unavailable or incompatible configuration is an error.

Historical HPC references must be verified and corrected deliberately in
the appropriate archived copies before analysis; the comparator does not
edit metadata.

These checks establish consistency with the available canonical configuration;
they do not, without an archived configuration copy or fingerprint, prove
bit-for-bit identity with a historical configuration.

## Daily/hourly continuous comparisons and the FUSE time convention

The primary cross-resolution comparison uses daily discharge:

- Daily FUSE simulations are compared against original CAMELS-NZ daily Qobs.
- Hourly FUSE simulations are aggregated using exactly 24 finite hourly
  values per calendar day, timestamped **00:30 through 23:30**. Hourly
  discharge in mm/h is summed to daily discharge in mm/day, then compared
  against the **same original daily Qobs** (not Qobs reconstructed from
  hourly observations).

The archived FUSE temporal convention affects endpoint coverage. In the
campaign examined here, daily simulations extend through **30 December
2009**, whereas complete hourly simulations extend through **31 December
2009**. Thus the hourly daily-aggregated evaluation can contain one extra
valid day.

Additional missing simulation values or incomplete hourly days may also
create differences in valid-date coverage.

**A targeted NSE/KGE (2009) recalculation may therefore be necessary solely
because of the FUSE temporal convention.**

`05_evaluation` calculates each simulation's metrics independently.
`03_compare_paired_daily.R` first checks that observations and timestamps
agree on common calendar days and compares valid-day counts within each
calibration/evaluation period.

It takes NSE and KGE (2009) directly from `05_evaluation` when the valid-day
sets are the same, and recalculates only the affected resolution and period
on the intersection of valid days otherwise.

The result records `metric_source_daily` and `metric_source_hourly` as
`05_evaluation` or `recomputed_common_days`.

The sign of each reported performance difference is **hourly aggregated
minus daily**.

Native hourly performance remains complementary and is not compared
directly with daily performance at a different timestep.

The FUSE endpoint convention explains the known one-day discrepancy; it
must not be used to ignore other coverage or configuration mismatches.

## Flood comparisons

`02_pair_floods.R` uses existing daily flood-unit metrics for both
resolutions (`flood_native_daily` for daily simulations and `flood_daily`
for hourly simulations aggregated to daily).

Units are identified by the same canonical observed flood catalogue and
paired by simulation identity and flood-unit identity.

Peak-discharge error, event-volume error and peak-timing difference are
**not recalculated** in this module.

The output retains validity and pairing information and provides basin-level
summaries to avoid treating catchments with more flood events as
disproportionately important.

Native hourly flood events remain a separate, complementary evaluation.

## Running the analysis

The commands below are intended for use **after the three analysis scripts
have been integrated into the repository**.

Run them from within a Git working tree containing the required evaluation
archives. All outputs go to a fresh directory in `/private/tmp`, not to
the archived experiments.

```bash
cd "$(git rev-parse --show-toplevel)"
REPO="$PWD"
RUN="$(mktemp -d /private/tmp/lse-camels-nz-06-analysis.XXXXXX)"

Rscript --vanilla scripts/06_analysis/01_collect_evaluations.R \
  "$REPO" "$RUN/evaluations" --check --strategies=kfold

Rscript --vanilla scripts/06_analysis/01_collect_evaluations.R \
  "$REPO" "$RUN/evaluations" --strategies=kfold

EVALUATIONS="$RUN/evaluations/evaluations_consolidated.rds"

Rscript --vanilla scripts/06_analysis/02_pair_floods.R \
  "$EVALUATIONS" "$RUN/floods" --check

Rscript --vanilla scripts/06_analysis/02_pair_floods.R \
  "$EVALUATIONS" "$RUN/floods"

Rscript --vanilla scripts/06_analysis/03_compare_paired_daily.R \
  "$REPO" "$EVALUATIONS" "$RUN/continuous" --check

Rscript --vanilla scripts/06_analysis/03_compare_paired_daily.R \
  "$REPO" "$EVALUATIONS" "$RUN/continuous"

printf 'Analysis outputs: %s\n' "$RUN"
```

The example restricts inventory to `kfold` to make the selection explicit.
Omit `--strategies=kfold` to inventory all configured strategies.

The `--check` option validates without writing analysis output.
Output directories must not already exist; use a new `RUN` directory
for each run.

If archived metadata still point to unavailable HPC configuration paths,
`03_compare_paired_daily.R` deliberately stops. Resolve the provenance
issue before rerunning; do not bypass the configuration check.

## Output objects

| Script | Output file | Main contents |
| --- | --- | --- |
| `01_collect_evaluations.R` | `evaluations_consolidated.rds` | `manifest`, `coverage`, `provenance`, descriptive continuous metrics, archived global and flood tables |
| `02_pair_floods.R` | `flood_comparisons.rds` | `paired_units`, `basin_summary`, matching/provenance information |
| `03_compare_paired_daily.R` | `continuous_comparisons.rds` | `paired_continuous`, valid-day counts, metric provenance, NSE/KGE (2009) differences, diagnostics |

The three output names are stable; incomplete campaign coverage is
represented inside the RDS objects rather than through filename suffixes.

The `continuous_metrics_descriptive` object in the evaluation collection
is **not** a substitute for a strictly paired daily/hourly comparison.

## Validation and limitations

The three scripts have been tested on a matched daily/hourly
`kfold/fold_01` emulator pair for basin `1316`.

The continuous comparison has additionally been tested with a temporary
`localcalib/sce` pair for that basin. These are targeted tests, not
full-campaign validation.

`01_collect_evaluations.R` and `02_pair_floods.R` do not rerun simulations
or individual evaluations.

`03_compare_paired_daily.R` reads archived hydrographs solely to establish
common-day coverage and, when required, perform targeted continuous-metric
recalculation. It does not calculate flood metrics.

All three scripts refuse to overwrite existing analysis output directories.

Full-campaign checks should examine completeness by strategy and partition,
configuration provenance, valid-day coverage, and uniqueness of basin-level
spatial comparisons before scientific aggregation or plotting.
