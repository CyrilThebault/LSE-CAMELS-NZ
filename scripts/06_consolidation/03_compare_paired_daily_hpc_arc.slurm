#!/bin/bash
#SBATCH --job-name=lse06_daily
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
#SBATCH --mail-type=FAIL
#SBATCH --output=logs/analysis/%x_%j.log
#SBATCH --error=logs/analysis/%x_%j.log

set -euo pipefail

# ARC software environment; matches existing HPC calibration launchers.
. /work/comphyd_lab/local/modules/spack/2024v5/lmod-init-bash
module purge
module unuse "$MODULEPATH"
module use /work/comphyd_lab/local/modules/spack/2024v5/modules/linux-rocky8-x86_64/Core/
module load gcc/14.2.0
module load cmake/3.30.2
module load hdf5/1.14.3
module load netcdf-c/4.9.2
module load netcdf-fortran/4.6.1
module load r/4.4.1

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

bash "$DIR_MAIN/scripts/06_consolidation/03_compare_paired_daily_local.sh" "$@"
