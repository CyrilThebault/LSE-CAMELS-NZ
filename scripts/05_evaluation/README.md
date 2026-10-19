# FUSE evaluation

## Individual evaluation

`01_evaluate_FUSE.R` evaluates one archived FUSE hydrograph.

It computes global and flood metrics for both temporal periods:
calibration and evaluation.

For hourly simulations, it also computes daily metrics after
aggregating simulated hourly discharge. Daily observations always
come from the original CAMELS-NZ daily forcing files.

The evaluator never runs FUSE.

## Experiment evaluation

`02_evaluate_experiment.R` evaluates archived simulations from
one experiment directory, independently of the experiment strategy.

Usage:

    Rscript scripts/05_evaluation/02_evaluate_experiment.R \
      <experiment_dir> <config_file> <dirMain> \
      [--step N] [--check|--force]

### Default selection: best

For emulators (RF, GBMv01, GBMv02):

- Evaluate only spatial test basins.
- Select the final configured refinement step
  (`nRefinementSteps`, currently 2).
- Each archived hydrograph must represent the rank-1 candidate
  selected by predicted eNKGE for its emulator, basin and step.
- This is NOT selection by observed FUSE KGEc or KGEe.
- An archived hydrograph must already exist; this launcher does
  not reproduce missing simulations.

For local calibration (`sce`):

- Use the optimal parameter set returned by local SCE calibration
  for each basin.
- No spatial train/test partition applies.
- Parameter optimization uses the temporal calibration period,
  not the independent temporal evaluation period.
- No refinement step applies.

The `best` convention describes two different parameter-selection
procedures. Their results are comparable as evaluation outputs,
but their selection procedures must not be conflated.

### Options

`--step N` selects an explicit emulator step instead of the final
step. It does not apply to local calibration.

`--check` computes evaluations without writing files.

By default, existing complete evaluations are preserved and skipped.
Incomplete or unexpected existing outputs cause an error.

`--force` explicitly allows replacement of existing evaluations.

Missing hydrographs are reported but never generated or replaced
with results from an earlier step.

## Spatial interpretation

For kfold, loo and cluster, the main regionalization analysis
combines test-basin results across folds.

The combined results must contain each basin exactly once per
method. This is checked when aggregating the results.

For allseen, test-phase results do not necessarily represent
spatial generalization to previously unseen basins.

The temporal calibration/evaluation split is independent of the
spatial train/test distinction.
