#!/bin/bash
#SBATCH --job-name=lse06_daily
#SBATCH --account=rrg-mclark
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/analysis/%x_%j.log
#SBATCH --error=logs/analysis/%x_%j.log

set -euo pipefail

# FIR software environment; matches existing HPC calibration launchers.
module --force purge
module load StdEnv/2023
module load gcc/12.3
module load cmake/3.31.0
module load hdf5/1.14.6
module load netcdf/4.9.3
module load netcdf-fortran/4.6.1
module load r/4.4.0
export HDF5_INCLUDE_DIR="$EBROOTHDF5/include"
export HDF5_LIB_DIR="$EBROOTHDF5/lib"

DIR_MAIN="${DIR_MAIN:?Set DIR_MAIN}"
CONFIG_FILE="${CONFIG_FILE:?Set CONFIG_FILE}"
export DIR_MAIN CONFIG_FILE

# Never exceed the cores allocated to this Slurm job.
NCORES="${SLURM_CPUS_PER_TASK:?Submit with --cpus-per-task}"
export NCORES

for arg in "$@"; do
  case "$arg" in
    --ncores=*)
      echo 'Do not override --ncores inside Slurm; use --cpus-per-task at submission.' >&2
      exit 2
      ;;
  esac
done

bash "$DIR_MAIN/scripts/06_analysis/03_compare_paired_daily_local.sh" "$@"
