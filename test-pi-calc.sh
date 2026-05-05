#!/bin/bash
# test-pi-calc-fixed.sh

NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-pi-calc.sh"
REMOTE_SCRIPT="/tmp/slinky-pi-calc.sh"

echo "1. Generating Distributed Pi Calculation job script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash

#SBATCH --job-name=slinky-calc-pi
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --tasks-per-node=2
#SBATCH --output=/tmp/pi-calc-%j.out
#SBATCH --error=/tmp/pi-calc-%j.err

echo "=== Distributed Monte Carlo Pi Estimation ==="
echo "Allocated Nodes: $SLURM_JOB_NODELIST"
echo "Total Tasks (Workers): $SLURM_NTASKS"

# We pass the unique seed value via the -v flag in the srun command below.
WORKER_SCRIPT='
BEGIN {
    # Seed the PRNG with the unique Slurm Process ID combined with system time
    srand(systime() + task_seed);
    inside = 0;
    points = 10000000;
    for (i = 0; i < points; i++) {
        x = rand(); 
        y = rand();
        if (x*x + y*y <= 1) {
            inside++;
        }
    }
    print inside, points, ENVIRON["SLURMD_NODENAME"];
}'

echo -e "\n1. Dispatching workload across nodes..."
echo "Each of the 4 tasks is calculating 10,000,000 unique points..."

# --- THE FIX ---
# We use awk's -v flag to pass $SLURM_PROCID directly into the awk script as 'task_seed'.
# This guarantees every task generates a completely different set of coordinates.
srun bash -c "export SLURMD_NODENAME=\$(hostname); awk -v task_seed=\$SLURM_PROCID '$WORKER_SCRIPT'" | awk '
{
    print "Received tally from " $3 ": " $1 " hits out of " $2 " points";
    total_inside += $1;
    total_points += $2;
}
END {
    pi = 4 * (total_inside / total_points);
    print "\n=== Final Aggregation ===";
    print "Total Points Processed across cluster: " total_points;
    print "Estimated value of Pi: " pi;
    
    error = (pi - 3.141592653589793) / 3.141592653589793 * 100;
    if (error < 0) error = -error;
    printf "Margin of Error: %.4f%%\n", error;
}'

echo -e "\nJob execution complete."
EOF

echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script to $CONTROLLER_POD."
    exit 1
fi

echo "3. Submitting the compute job via sbatch..."
JOB_SUBMIT_OUTPUT=$(kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT | tr -d '\r')
echo "$JOB_SUBMIT_OUTPUT"
JOB_ID=$(echo "$JOB_SUBMIT_OUTPUT" | awk '{print $4}')

echo "----------------------------------------"
echo "4. Checking the Slurm queue..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "To view the results once the job completes, run:"
echo "kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /tmp/pi-calc-${JOB_ID}.out"