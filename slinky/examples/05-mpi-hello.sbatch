#!/bin/bash
#SBATCH --job-name=mpi-hello
#SBATCH --partition=general
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --output=/tmp/mpi-hello-%j.out

# 4 MPI ranks across 2 worker nodes (2 per node), launched via srun + PMIx.
# Falls back to apt-installing OpenMPI if the slurmd image lacks it.

set -e

if ! command -v mpicc >/dev/null 2>&1; then
  echo "mpicc not found — installing openmpi (one-time)"
  apt-get update -qq && apt-get install -y -qq openmpi-bin libopenmpi-dev gcc
fi

cat > /tmp/mpi-hello.c <<'EOF'
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char** argv) {
  int rank, size;
  char host[256];
  MPI_Init(&argc, &argv);
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);
  gethostname(host, sizeof host);
  printf("Hello from rank %d/%d on %s\n", rank, size, host);
  fflush(stdout);
  MPI_Finalize();
  return 0;
}
EOF
mpicc -O2 -o /tmp/mpi-hello /tmp/mpi-hello.c

# Prefer SLURM-native PMIx; fall back to pmi2 if pmix isn't built in.
if srun --mpi=list 2>&1 | grep -q pmix; then
  srun --mpi=pmix /tmp/mpi-hello
else
  srun --mpi=pmi2 /tmp/mpi-hello
fi
