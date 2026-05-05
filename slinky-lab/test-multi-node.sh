#!/bin/bash
# test-multi-node.sh

NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-multinode.sh"
REMOTE_SCRIPT="/tmp/slinky-multinode.sh"

echo "1. Generating multi-node Slurm batch job script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash
#SBATCH --job-name=slinky-mpi-sim
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --tasks-per-node=2
#SBATCH --output=/tmp/multi-node-%j.out
#SBATCH --error=/tmp/multi-node-%j.err

echo "=== Cluster Allocation Status ==="
echo "Allocated Nodes: $SLURM_JOB_NODELIST"
echo "Total Tasks Allocated: $SLURM_NTASKS"
echo "Tasks per Node: $SLURM_TASKS_PER_NODE"

echo -e "\n=== Parallel Task Execution (srun) ==="
# srun acts as the MPI coordinator here. 
# It runs this exact command exactly 4 times, distributed across the 2 nodes.
srun bash -c 'echo "Task ID $SLURM_PROCID executing on hardware slice: $(hostname)"'

echo -e "\nJob execution complete."
EOF

echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script to $CONTROLLER_POD."
    exit 1
fi

echo "3. Submitting the multi-node job via sbatch..."
# Capture the Job ID directly from the sbatch output
JOB_SUBMIT_OUTPUT=$(kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT | tr -d '\r')
echo "$JOB_SUBMIT_OUTPUT"
JOB_ID=$(echo "$JOB_SUBMIT_OUTPUT" | awk '{print $4}')

echo "----------------------------------------"
echo "4. Checking the Slurm queue..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "To view the results once the job completes, run:"
echo "kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /tmp/multi-node-${JOB_ID}.out"