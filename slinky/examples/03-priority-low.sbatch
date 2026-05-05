#!/bin/bash
#SBATCH --job-name=low
#SBATCH --partition=general
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:10:00
#SBATCH --output=/tmp/low-%j.out

# Long, low-priority job that occupies both workers.
# Submit this first, then 03-priority-high.sbatch and watch how the scheduler
# treats them — by PriorityTier, the "priority" partition wins.

echo "[low] starting on ${SLURM_JOB_NODELIST}"
for i in $(seq 1 600); do echo "[low] tick $i"; sleep 1; done
