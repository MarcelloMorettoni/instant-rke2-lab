#!/bin/bash
#SBATCH --job-name=arr
#SBATCH --partition=general
#SBATCH --array=0-9
#SBATCH --time=00:02:00
#SBATCH --output=/tmp/arr-%A_%a.out

# Job array: 10 tasks numbered 0..9. Demonstrates how the backfill scheduler
# fans out work across both worker nodes when each task is small.

echo "task ${SLURM_ARRAY_TASK_ID} of array ${SLURM_ARRAY_JOB_ID}"
echo "running on $(hostname)"
sleep $(( (RANDOM % 10) + 5 ))
echo "task ${SLURM_ARRAY_TASK_ID} done"
