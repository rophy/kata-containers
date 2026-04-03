#!/bin/bash
#
# Run Kata integration tests against a k3s+CRI-O Multipass VM.
#
# Usage:
#   ./run-vm-k3s.sh [bats-file ...]
#
# If no files specified, runs the default test set.
#
# Prerequisites:
#   - Multipass VM named "kata-dev" with k3s + CRI-O + kata-deploy
#   - Patched runtime-rs shim + agent deployed
#   - Repo cloned at /home/ubuntu/kata-containers on the VM
#
# Environment:
#   VM_NAME         - Multipass VM name (default: kata-dev)
#   KATA_HYPERVISOR - Kata hypervisor (default: qemu-coco-dev-rs)
#   K8S_TEST_FAIL_FAST - Stop on first failure (default: no)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
VM_NAME="${VM_NAME:-kata-dev}"
KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu-coco-dev-rs}"
K8S_TEST_FAIL_FAST="${K8S_TEST_FAIL_FAST:-no}"

# Default test set — tests known to work with k3s + CRI-O + QEMU
DEFAULT_TESTS=(
    "k8s-block-volume-automount.bats"
    "k8s-env.bats"
    "k8s-hostname.bats"
    "k8s-caps.bats"
    "k8s-configmap.bats"
    "k8s-copy-file.bats"
    "k8s-cron-job.bats"
    "k8s-empty-dirs.bats"
    "k8s-exec.bats"
    "k8s-file-volume.bats"
    "k8s-inotify.bats"
    "k8s-job.bats"
    "k8s-limit-range.bats"
    "k8s-memory.bats"
    "k8s-oom.bats"
    "k8s-pid-ns.bats"
    "k8s-pod-quota.bats"
    "k8s-port-forward.bats"
    "k8s-projected-volume.bats"
    "k8s-replication.bats"
    "k8s-seccomp.bats"
    "k8s-security-context.bats"
    "k8s-volume.bats"
    "k8s-block-volume.bats"
)

TESTS=("${@:-${DEFAULT_TESTS[@]}}")

info() { echo "[$(date +%H:%M:%S)] INFO: $*"; }

# Step 1: Sync our custom test files to the VM's repo clone
info "Syncing test files to VM..."
VM_REPO="/home/ubuntu/kata-containers"

# Ensure repo exists on VM
multipass exec "$VM_NAME" -- bash -c "
    [ -d '$VM_REPO/.git' ] || git clone --depth 1 https://github.com/kata-containers/kata-containers.git '$VM_REPO' 2>&1 | tail -1
"

# Sync our custom/modified test files
for f in "${TESTS[@]}"; do
    src="${SCRIPT_DIR}/${f}"
    if [ -f "$src" ]; then
        multipass transfer "$src" "${VM_NAME}:${VM_REPO}/tests/integration/kubernetes/${f}"
    fi
done

# Step 2: Run tests inside VM
info "Running ${#TESTS[@]} test(s) in VM..."
multipass exec "$VM_NAME" -- sudo bash -c "
set -uo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KATA_HYPERVISOR='${KATA_HYPERVISOR}'
export AUTO_GENERATE_POLICY=no
export K8S_TEST_FAIL_FAST='${K8S_TEST_FAIL_FAST}'
export PATH=\$PATH:/usr/local/bin

cd '${VM_REPO}/tests/integration/kubernetes'

# Run setup to generate workload configs
bash setup.sh 2>&1 | tail -1

# Run tests
PASS=0
FAIL=0
SKIP=0
ERRORS=()

for test_file in ${TESTS[*]}; do
    if [ ! -f \"\$test_file\" ]; then
        echo \"SKIP: \$test_file (not found)\"
        SKIP=\$((SKIP + 1))
        continue
    fi

    echo \"\"
    echo \"========================================\"
    echo \"Running: \$test_file\"
    echo \"========================================\"

    if bats \"\$test_file\"; then
        PASS=\$((PASS + 1))
    else
        FAIL=\$((FAIL + 1))
        ERRORS+=(\"\$test_file\")
        if [ '${K8S_TEST_FAIL_FAST}' = 'yes' ]; then
            echo 'FAIL FAST: stopping after first failure'
            break
        fi
    fi
done

echo \"\"
echo \"========================================\"
echo \"RESULTS: \$PASS passed, \$FAIL failed, \$SKIP skipped out of \$((PASS + FAIL + SKIP))\"
if [ \$FAIL -gt 0 ]; then
    echo \"Failed:\"
    for f in \"\${ERRORS[@]}\"; do
        echo \"  - \$f\"
    done
fi
echo \"========================================\"

[ \$FAIL -eq 0 ]
"

info "Done."
