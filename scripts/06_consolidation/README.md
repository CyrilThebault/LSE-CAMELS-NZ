# Consolidation of archived FUSE evaluations

For the complete workflow, see the [repository README](../../README.md).

This module collects, validates, harmonizes and pairs individual evaluation
results produced by `scripts/05_evaluation/`. It publishes canonical tables
with complete simulation identities, metric values, validity information
and provenance. Figure-specific differences, aggregation and statistical
analyses belong to `07_plots`.

`06_consolidation` does not run FUSE, recalibrate models, redetect observed
flood events or generate figures.

## Workflow and responsibilities

Run the scripts in this order:

1. `01_collect_evaluations.R` inventories available evaluation archives and
   consolidates their metrics without recalculating them.
2. `02_pair_floods.R` pairs previously evaluated daily flood units and
   retains their individual metrics and validity information. It does not
   recalculate flood metrics or produce basin-level summaries.
3. `03_compare_paired_daily.R` harmonizes daily NSE and KGE (2009) for
   daily and hourly simulations on strictly common valid days. It reuses
   archived metrics whenever their original valid-day coverage matches
   the paired coverage.

Missing evaluations are recorded in the manifest and coverage tables.
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

Configuration checks establish consistency with the available canonical
configuration. Exact identity with the configuration used to generate the
simulations requires an archived configuration copy or fingerprint.

## Daily/hourly continuous comparisons and the FUSE time convention

The primary cross-resolution comparison uses daily discharge:

- Daily FUSE simulations are compared against original CAMELS-NZ daily Qobs.
- Hourly FUSE simulations are aggregated using exactly 24 finite hourly
  values per calendar day, timestamped **00:30 through 23:30**. Hourly
  discharge in mm/h is summed to daily discharge in mm/day, then compared
  against the **same original daily Qobs** (not Qobs reconstructed from
  hourly observations).

Daily and hourly FUSE simulations can differ in endpoint coverage.
Missing simulation values and incomplete hourly days can also affect the
set of valid dates. Common-day coverage is established separately for
each simulation and evaluation period.

`05_evaluation` calculates each simulation's metrics independently.
`03_compare_paired_daily.R` first checks that observations and timestamps
agree on common calendar days and compares valid-day counts within each
calibration/evaluation period.

It takes NSE and KGE (2009) directly from `05_evaluation` when the valid-day
sets are the same, and recalculates only the affected resolution and period
on the intersection of valid days otherwise.

The result records `metric_source_daily` and `metric_source_hourly` as
`05_evaluation` or `recomputed_common_days`.

The output retains daily and hourly performance values separately.
Performance differences are calculated only by the downstream figure
scripts that require them.

Native hourly performance remains complementary and is not compared
directly with daily performance at a different timestep.

## Flood comparisons

`02_pair_floods.R` uses existing daily flood-unit metrics for both
resolutions (`flood_native_daily` for daily simulations and `flood_daily`
for hourly simulations aggregated to daily).

Units are identified by the same canonical observed flood catalogue and
paired by simulation identity and flood-unit identity.

Peak-discharge error, event-volume error and peak-timing difference are
**not recalculated** in this module.

The output retains individual flood-unit metrics, validity flags and
pairing information. Aggregation and weighting decisions are made by
downstream figure scripts according to their scientific objectives.

Native hourly flood events remain a separate, complementary evaluation.

## Running the consolidation

The example below runs the three stages locally from the repository root.
It inventories all configured strategies, including incomplete ones.
Outputs are written to a new directory under `/private/tmp`; archived
simulations and evaluations are not modified.

```bash
cd "$(git rev-parse --show-toplevel)"

export DIR_MAIN="$PWD"
export CONFIG_FILE="$DIR_MAIN/config/experiment.R"

RUN="$(mktemp -d /private/tmp/lse-camels-nz-06-consolidation.XXXXXX)"

# Step 1: Collect evaluation results
Rscript --vanilla scripts/06_consolidation/01_collect_evaluations.R "$DIR_MAIN" "$RUN/evaluations" --check
Rscript --vanilla scripts/06_consolidation/01_collect_evaluations.R "$DIR_MAIN" "$RUN/evaluations"

EVALUATIONS="$RUN/evaluations/evaluations_consolidated.rds"

# Step 2: Pair daily flood units
Rscript --vanilla scripts/06_consolidation/02_pair_floods.R "$EVALUATIONS" "$RUN/floods" --check
Rscript --vanilla scripts/06_consolidation/02_pair_floods.R "$EVALUATIONS" "$RUN/floods"

# Step 3: Harmonize daily and hourly continuous metrics
bash scripts/06_consolidation/03_compare_paired_daily_local.sh "$EVALUATIONS" "$RUN/continuous" --ncores=8

echo "Consolidation outputs: $RUN"
```

To inspect only selected strategies, pass, for example,
`--strategies=kfold` to the collector. Adjust `--ncores=8` to the
available resources. The collector and flood-pairing `--check` modes
validate without publishing files. For stage 03, `--check` performs
the full common-day processing without writing its output; it is not
a lightweight preflight.

Each output directory must be new. The example uses `/private/tmp` on
macOS; for ARC or FIR use paths accessible from the compute nodes.
If archived metadata reference unavailable or incompatible historical
configurations, stage 03 stops rather than silently substituting them.

## Parallel execution of continuous comparisons

`03_compare_paired_daily.R` supports optional multicore execution on
macOS and Linux through `parallel::mclapply()`.

The number of workers is controlled by `--ncores=N`. Direct R execution
defaults to one core, preserving sequential behavior.

Three launchers are available:

- `03_compare_paired_daily_local.sh`: local execution with configurable cores.
- `03_compare_paired_daily_hpc_arc.slurm`: multicore execution on ARC.
- `03_compare_paired_daily_hpc_fir.slurm`: multicore execution on FIR.

The local launcher requires `DIR_MAIN` and `CONFIG_FILE`. The latter must
reference the canonical `config/experiment.R`.

On HPC, the number of workers follows `SLURM_CPUS_PER_TASK`, configured
through the SLURM CPU allocation rather than an explicit `--ncores` override.
Create `logs/analysis/` before submitting a job, and ensure that the input
RDS, output parent directory and repository are accessible to compute nodes.

Stages 01 and 02 run sequentially. Stage 03 supports parallel execution.

Stage 03 assembles results in deterministic order. Failed workers prevent
publication of incomplete results.

The optional `--check` mode performs the full comparison without writing
output files. It is not a lightweight preliminary inspection.

## Output organization

| Script | Output file | Main contents |
| --- | --- | --- |
| `01_collect_evaluations.R` | `evaluations_consolidated.rds` | `manifest`, `coverage`, `provenance`, descriptive continuous metrics, archived global and flood tables |
| `02_pair_floods.R` | `flood_comparisons.rds` | `paired_units`, individual daily/hourly flood metrics, validity flags and pairing information |
| `03_compare_paired_daily.R` | `continuous_comparisons.rds` | `paired_continuous`, harmonized daily/hourly NSE and KGE (2009), valid-day counts, metric provenance and diagnostics |

Incomplete campaign coverage is represented in the RDS outputs.

The `continuous_metrics_descriptive` table contains archived metric values.
The `paired_continuous` table contains metrics harmonized on common valid
days.

## Validation and safe reruns

`01_collect_evaluations.R` and `02_pair_floods.R` do not rerun simulations
or individual evaluations.

`03_compare_paired_daily.R` reads archived hydrographs solely to establish
common-day coverage and, when required, perform targeted continuous-metric
recalculation. It does not calculate flood metrics.

All three scripts refuse to overwrite existing consolidation output directories.

## Related documentation

- [Main workflow](../../README.md)
- [Individual FUSE evaluations](../05_evaluation/README.md)
