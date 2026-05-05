#!/bin/bash
#SBATCH --job-name=high
#SBATCH --partition=priority
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:01:00
#SBATCH --output=/tmp/high-%j.out

# Submit AFTER 03-priority-low.sbatch. The "priority" partition has
# PriorityTier=10 vs general's 1, so this job moves ahead in the queue.

echo "[high] running on $(hostname)"
sleep 10
echo "[high] done"
