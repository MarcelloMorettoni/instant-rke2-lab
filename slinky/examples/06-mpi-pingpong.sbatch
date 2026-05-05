#!/bin/bash
#SBATCH --job-name=mpi-pp
#SBATCH --partition=general
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:05:00
#SBATCH --output=/tmp/mpi-pp-%j.out

# Inter-node MPI ping-pong. Useful for sanity-checking that the CNI overlay
# (Cilium eBPF) doesn't mangle MPI traffic. Reports rough one-way latency
# per message size — values will be much higher than bare-metal because
# every packet rides through the host's virbr0 bridge plus the Cilium tunnel.

set -e
if ! command -v mpicc >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq openmpi-bin libopenmpi-dev gcc
fi

cat > /tmp/mpi-pp.c <<'EOF'
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
  int rank, size, iters = 1000;
  MPI_Init(&argc, &argv);
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);
  if (size != 2) { if (rank==0) fprintf(stderr, "needs 2 ranks\n"); MPI_Finalize(); return 1; }

  size_t sizes[] = { 8, 64, 512, 4096, 65536, 1048576 };
  for (int s = 0; s < (int)(sizeof(sizes)/sizeof(*sizes)); ++s) {
    char* buf = malloc(sizes[s]);
    memset(buf, 0xab, sizes[s]);
    MPI_Barrier(MPI_COMM_WORLD);
    double t0 = MPI_Wtime();
    for (int i = 0; i < iters; ++i) {
      if (rank == 0) {
        MPI_Send(buf, sizes[s], MPI_BYTE, 1, 0, MPI_COMM_WORLD);
        MPI_Recv(buf, sizes[s], MPI_BYTE, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
      } else {
        MPI_Recv(buf, sizes[s], MPI_BYTE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        MPI_Send(buf, sizes[s], MPI_BYTE, 0, 0, MPI_COMM_WORLD);
      }
    }
    double t1 = MPI_Wtime();
    if (rank == 0) {
      double per_msg_us = ((t1 - t0) * 1e6) / (2.0 * iters);
      printf("%8zu bytes  one-way avg %.2f us\n", sizes[s], per_msg_us);
      fflush(stdout);
    }
    free(buf);
  }
  MPI_Finalize();
  return 0;
}
EOF
mpicc -O2 -o /tmp/mpi-pp /tmp/mpi-pp.c

if srun --mpi=list 2>&1 | grep -q pmix; then
  srun --mpi=pmix /tmp/mpi-pp
else
  srun --mpi=pmi2 /tmp/mpi-pp
fi
