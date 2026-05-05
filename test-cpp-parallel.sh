#!/bin/bash
# test-cpp-parallel.sh

NAMESPACE="slurm"
CONTROLLER_POD="slurm-controller-0"
LOCAL_SCRIPT="/tmp/slinky-cpp.sh"
REMOTE_SCRIPT="/tmp/slinky-cpp.sh"

echo "1. Generating Distributed C++ job script..."
cat << 'EOF' > $LOCAL_SCRIPT
#!/bin/bash
#SBATCH --job-name=slinky-cpp
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --tasks-per-node=2
#SBATCH --output=/tmp/cpp-parallel-%j.out
#SBATCH --error=/tmp/cpp-parallel-%j.err

echo "=== Distributed C++ Compilation and Execution ==="
echo "Allocated Nodes: $SLURM_JOB_NODELIST"

# --- DISTRIBUTED COMPILATION & EXECUTION ---
# We pass a multi-line bash command into srun. 
# srun will execute this entire block simultaneously across all 4 tasks.
# Note: We append $SLURM_PROCID to the filenames. Because 2 tasks run on the same 
# node (and thus share the same /tmp directory), this prevents a race condition 
# where both tasks try to write to 'worker.cpp' at the exact same millisecond.

srun bash -c '
# 1. Write the C++ source code to the local pod filesystem
cat << "CPPEOF" > /tmp/task_${SLURM_PROCID}.cpp
#include <iostream>
#include <cstdlib>

int main() {
    // Read the environment variables injected by Slurm
    const char* rank = std::getenv("SLURM_PROCID");
    const char* node = std::getenv("SLURMD_NODENAME");
    
    // Simulate some local compute work
    double result = 0.0;
    for(int i=0; i<10000; i++) {
        result += i * 0.001;
    }
    
    std::cout << "[C++ Binary] Hello from Task " << (rank ? rank : "N/A") 
              << " executing natively on pod: " << (node ? node : "N/A") 
              << " | Dummy compute result: " << result << std::endl;
    
    return 0;
}
CPPEOF

# 2. Compile the C++ code using g++
g++ -O3 /tmp/task_${SLURM_PROCID}.cpp -o /tmp/task_bin_${SLURM_PROCID}

if [ $? -ne 0 ]; then
    echo "Error: Compilation failed on task ${SLURM_PROCID}"
    exit 1
fi

# 3. Execute the compiled binary natively
/tmp/task_bin_${SLURM_PROCID}
'

echo -e "\nJob execution complete."
EOF

echo "2. Transferring job script to the Slurm controller pod..."
kubectl cp $LOCAL_SCRIPT $NAMESPACE/$CONTROLLER_POD:$REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    echo "Error: Failed to copy script to $CONTROLLER_POD. Is the pod ready?"
    exit 1
fi

echo "3. Submitting the C++ compute job via sbatch..."
JOB_SUBMIT_OUTPUT=$(kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- sbatch $REMOTE_SCRIPT | tr -d '\r')
echo "$JOB_SUBMIT_OUTPUT"
JOB_ID=$(echo "$JOB_SUBMIT_OUTPUT" | awk '{print $4}')

echo "----------------------------------------"
echo "4. Checking the Slurm queue..."
kubectl exec -it -n $NAMESPACE $CONTROLLER_POD -- squeue

echo "----------------------------------------"
echo "To view the C++ execution results once the job completes, run:"
echo "kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /tmp/cpp-parallel-${JOB_ID}.out"