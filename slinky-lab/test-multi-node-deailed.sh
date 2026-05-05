#!/bin/bash
# test-multi-node-detailed.sh

# ==========================================
# 1. ENVIRONMENT VARIABLES
# ==========================================
# In a traditional HPC cluster, you run 'sbatch' directly from a login node.
# In Slinky, we must route our commands through Kubernetes to the controller pod.
NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-multinode.sh"
REMOTE_SCRIPT="/tmp/slinky-multinode.sh"

# ==========================================
# 2. CREATE THE SLURM BATCH SCRIPT
# ==========================================
# This 'cat' command generates the actual script that Slurm will execute.
# The EOF block contains the native Slurm syntax, unmodified for Kubernetes.
echo "1. Generating multi-node Slurm batch job script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash

# --- SBATCH DIRECTIVES (The Resource Request) ---
# These #SBATCH comments are read by the Slurm scheduler before execution.
# They define the exact hardware slice we are requesting from the NodeSet.

#SBATCH --job-name=slinky-mpi-sim
# Request exactly 2 compute nodes (which maps to your 2 Slinky worker pods).
#SBATCH --nodes=2
# Request a total of 4 tasks (processes) for this job.
#SBATCH --ntasks=4
# Force Slurm to distribute the 4 tasks evenly: 2 tasks on node 0, 2 tasks on node 1.
#SBATCH --tasks-per-node=2
# Define where the standard output and error files should be written.
# Note: In our current setup, this writes to the local /tmp of the execution pod.
#SBATCH --output=/tmp/multi-node-%j.out
#SBATCH --error=/tmp/multi-node-%j.err

# --- EXECUTION BLOCK ---
# This part runs exactly ONCE on the primary allocated node (e.g., slinky-0).

echo "=== Cluster Allocation Status ==="
echo "Allocated Nodes: $SLURM_JOB_NODELIST"
echo "Total Tasks Allocated: $SLURM_NTASKS"
echo "Tasks per Node: $SLURM_TASKS_PER_NODE"

echo -e "\n=== Parallel Task Execution (srun) ==="
# srun is the critical component here. It acts as the parallel task coordinator.
# Because we requested 4 tasks across 2 nodes, srun will take the command following it
# (bash -c 'echo...') and execute it simultaneously 4 times across the network.
# It handles the MPI-like distribution automatically without needing SSH keys.
srun bash -c 'echo "Task ID $SLURM_PROCID executing on hardware slice: $(hostname)"'

echo -e "\nJob execution complete."
EOF

# ==========================================
# 3. TRANSFER THE SCRIPT TO THE CLUSTER
# ==========================================
# Because our Slinky cluster lacks a shared network drive (NFS), the controller pod
# cannot see the file we just created on our local machine. We must physically copy
# the script into the controller pod's local filesystem first.
echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script to $CONTROLLER_POD."
    exit 1
fi

# ==========================================
# 4. SUBMIT THE JOB
# ==========================================
# We use 'kubectl exec' to reach into the controller pod and execute the standard
# 'sbatch' command against the script we just copied over.
echo "3. Submitting the multi-node job via sbatch..."
# We capture the output string (e.g., "Submitted batch job 3") and parse out the ID.
JOB_SUBMIT_OUTPUT=$(kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT | tr -d '\r')
echo "$JOB_SUBMIT_OUTPUT"
JOB_ID=$(echo "$JOB_SUBMIT_OUTPUT" | awk '{print $4}')

# ==========================================
# 5. MONITORING AND VERIFICATION
# ==========================================
echo "----------------------------------------"
echo "4. Checking the Slurm queue..."
# Display the queue. Because you now have 2 worker replicas ready, this job should
# quickly transition from PD (Pending) to R (Running) or disappear entirely 
# once completed.
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "To view the results once the job completes, run:"
# We hardcode 'slurm-worker-slinky-0' here because Slurm designates the lowest-numbered
# node in the allocation as the primary node, and that is where the batch script 
# executes and writes its standard output.
echo "kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /tmp/multi-node-${JOB_ID}.out"