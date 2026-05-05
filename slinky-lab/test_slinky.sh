#!/bin/bash
# test-slinky.sh

NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-test-job.sh"
REMOTE_SCRIPT="/tmp/slinky-test-job.sh"

echo "1. Generating Slurm batch job script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash
#SBATCH --job-name=slinky-test
#SBATCH --output=/tmp/slinky-test-%j.out
#SBATCH --error=/tmp/slinky-test-%j.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00

echo "Hello from Slinky on Kubernetes!"
echo "Execution Node: $(hostname)"
srun sleep 15
echo "Job finished."
EOF

echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script to $CONTROLLER_POD. Is the pod ready?"
    exit 1
fi

echo "3. Submitting the job via sbatch..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT

echo "----------------------------------------"
echo "4. Checking the Slurm queue (squeue)..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "5. Checking cluster node status (sinfo)..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sinfo