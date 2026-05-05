#!/bin/bash
# test-chunking.sh

NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-chunking.sh"
REMOTE_SCRIPT="/tmp/slinky-chunking.sh"

echo "1. Generating Distributed Data Chunking script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash
#SBATCH --job-name=slinky-chunking
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --tasks-per-node=2
#SBATCH --output=/tmp/chunking-%j.out
#SBATCH --error=/tmp/chunking-%j.err

echo "=== Distributed Data Chunking Example ==="
echo "Allocated Nodes: $SLURM_JOB_NODELIST"
echo "Total Tasks: $SLURM_NTASKS"

# --- THE WORKER PAYLOAD (MAP PHASE) ---
WORKER_SCRIPT='
BEGIN {
    total_items = 100000000;
    
    # Read the environment variables injected by Slurm
    tasks = ENVIRON["SLURM_NTASKS"];
    rank = ENVIRON["SLURM_PROCID"];
    node = ENVIRON["SLURMD_NODENAME"];
    
    # Calculate the mathematical boundaries for this specific task
    chunk_size = total_items / tasks;
    start_val = (rank * chunk_size) + 1;
    end_val = (rank + 1) * chunk_size;
    
    # Process the chunk
    partial_sum = 0;
    for (i = start_val; i <= end_val; i++) {
        partial_sum += i;
    }
    
    # Send the result back to the primary node
    printf "Task %d on %s processed range [%10d to %10d] -> Partial Sum: %d\n", rank, node, start_val, end_val, partial_sum;
}'

echo -e "\n1. Dispatching unique data chunks across nodes..."

# --- THE AGGREGATOR (REDUCE PHASE) ---
# FIX: Removed the backslash before $WORKER_SCRIPT so it expands properly before network dispatch.
srun bash -c "export SLURM_NTASKS=\$SLURM_NTASKS; export SLURM_PROCID=\$SLURM_PROCID; export SLURMD_NODENAME=\$(hostname); awk '$WORKER_SCRIPT'" | awk '
{
    print $0; # Print the raw output from the worker node
    
    # Extract the partial sum (which is the last field in our printed string)
    total_sum += $NF;
}
END {
    print "\n=== Final Aggregation ===";
    # Using printf to handle the massive number without scientific notation
    printf "Grand Total Sum (1 to 100,000,000): %.0f\n", total_sum;
    
    # We can verify the math using the formula n*(n+1)/2
    n = 100000000;
    expected = (n * (n + 1)) / 2;
    printf "Mathematical Verification:          %.0f\n", expected;
    
    if (total_sum == expected) {
        print "Status: SUCCESS - Distributed calculation is perfectly accurate.";
    } else {
        print "Status: FAILED - Calculation mismatch.";
    }
}'

echo -e "\nJob execution complete."
EOF

echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script."
    exit 1
fi

echo "3. Submitting the chunking job via sbatch..."
JOB_SUBMIT_OUTPUT=$(kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT | tr -d '\r')
echo "$JOB_SUBMIT_OUTPUT"
JOB_ID=$(echo "$JOB_SUBMIT_OUTPUT" | awk '{print $4}')

echo "----------------------------------------"
echo "4. Checking the Slurm queue..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "To view the chunking results once the job completes, run:"
echo "kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /tmp/chunking-${JOB_ID}.out"