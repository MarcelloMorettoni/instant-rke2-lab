#!/bin/bash
#SBATCH --job-name=multinode
#SBATCH --partition=general
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:02:00
#SBATCH --output=/tmp/multinode-%j.out

# No MPI library required — just demonstrates SLURM dispatching one task
# per worker and collecting their stdout. Sanity check before the MPI demo.

echo "Allocated nodes: ${SLURM_JOB_NODELIST}"
srun bash -c 'echo "  rank=${SLURM_PROCID} host=$(hostname) cpus=$(nproc)"'
