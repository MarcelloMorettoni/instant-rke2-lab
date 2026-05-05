#!/bin/bash
#SBATCH --job-name=hello
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:01:00
#SBATCH --output=/tmp/hello-%j.out
#SBATCH --error=/tmp/hello-%j.err

echo "== hello world =="
echo "Job:      ${SLURM_JOB_ID}"
echo "Node:     $(hostname)"
echo "Partition:${SLURM_JOB_PARTITION}"
echo "Date:     $(date -u +%FT%TZ)"
sleep 5
echo "done"
