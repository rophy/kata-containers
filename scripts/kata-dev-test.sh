#!/usr/bin/env bash
#
# Run BATS integration tests against the kata-dev VM.
#
# Usage:
#   ./scripts/kata-dev-test.sh                    # run all applicable tests
#   ./scripts/kata-dev-test.sh k8s-env.bats       # run a specific test
#   ./scripts/kata-dev-test.sh k8s-env.bats k8s-exec.bats  # run multiple
#   ./scripts/kata-dev-test.sh --list              # list tests that would run
#   ./scripts/kata-dev-test.sh --setup-only        # only run setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tests/integration/kubernetes"

# --- environment for kata-dev VM with k3s + CRI-O + kata-deploy (qemu-coco-dev) ---

VM_NAME="kata-dev"
KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

export KUBECONFIG="${KUBECONFIG_HOST}"
export KATA_HYPERVISOR="qemu-coco-dev"
export KUBERNETES="k3s"
export AUTO_GENERATE_POLICY="no"

# Tests that are safe to run on single-node k3s + CRI-O + kata (qemu-coco-dev)
# Excluded: confidential, nvidia, guest-pull, policy, sealed-secret, measured-rootfs,
#           openvpn, empty-image, footloose, sandbox-cgroup, sandbox-vcpus
TESTS_ALL=(
    k8s-attach-handlers.bats
    k8s-caps.bats
    k8s-configmap.bats
    k8s-copy-file.bats
    k8s-cpu-ns.bats
    k8s-credentials-secrets.bats
    k8s-cron-job.bats
    k8s-custom-dns.bats
    k8s-empty-dirs.bats
    k8s-env.bats
    k8s-exec.bats
    k8s-file-volume.bats
    k8s-hostname.bats
    k8s-inotify.bats
    k8s-job.bats
    k8s-kill-all-process-in-container.bats
    k8s-limit-range.bats
    k8s-liveness-probes.bats
    k8s-memory.bats
    k8s-nested-configmap-secret.bats
    k8s-nginx-connectivity.bats
    k8s-number-cpus.bats
    k8s-oom.bats
    k8s-optional-empty-configmap.bats
    k8s-optional-empty-secret.bats
    k8s-parallel.bats
    k8s-pid-ns.bats
    k8s-pod-quota.bats
    k8s-port-forward.bats
    k8s-privileged.bats
    k8s-projected-volume.bats
    k8s-qos-pods.bats
    k8s-replication.bats
    k8s-scale-nginx.bats
    k8s-seccomp.bats
    k8s-security-context.bats
    k8s-shared-volume.bats
    k8s-sysctls.bats
    k8s-volume.bats
)

# --- helpers ---

log() { echo "==> $*"; }

ensure_kubeconfig() {
    if [ ! -f "${KUBECONFIG_HOST}" ]; then
        log "Exporting kubeconfig from ${VM_NAME}..."
        local vm_ip
        vm_ip=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f3)
        multipass exec "$VM_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml \
            | sed "s|127.0.0.1|${vm_ip}|" > "${KUBECONFIG_HOST}"
    fi
    # Verify connectivity
    if ! kubectl get nodes &>/dev/null; then
        echo "ERROR: Cannot reach cluster. Is ${VM_NAME} running?" >&2
        exit 1
    fi
}

run_setup() {
    log "Running test setup (KATA_HYPERVISOR=${KATA_HYPERVISOR}, KUBERNETES=${KUBERNETES})..."
    (cd "${TEST_DIR}" && bash setup.sh)
}

# --- main ---

# Parse args
SETUP_ONLY=false
LIST_ONLY=false
SELECTED_TESTS=()

for arg in "$@"; do
    case "$arg" in
        --setup-only) SETUP_ONLY=true ;;
        --list) LIST_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--list|--setup-only] [test1.bats test2.bats ...]"
            exit 0
            ;;
        *.bats) SELECTED_TESTS+=("$arg") ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ ${#SELECTED_TESTS[@]} -eq 0 ]]; then
    SELECTED_TESTS=("${TESTS_ALL[@]}")
fi

if [[ "$LIST_ONLY" == "true" ]]; then
    printf '%s\n' "${SELECTED_TESTS[@]}"
    exit 0
fi

ensure_kubeconfig

run_setup

if [[ "$SETUP_ONLY" == "true" ]]; then
    log "Setup complete."
    exit 0
fi

LOG_FILE="/tmp/kata-dev-bats-$(date +%Y%m%d-%H%M%S).log"

log "Running ${#SELECTED_TESTS[@]} tests..."
log "  KATA_HYPERVISOR=${KATA_HYPERVISOR}"
log "  KUBERNETES=${KUBERNETES}"
log "  KUBECONFIG=${KUBECONFIG}"
log "  Log: ${LOG_FILE}"
log ""

cd "${TEST_DIR}"

set +e
bats --formatter tap "${SELECTED_TESTS[@]}" 2>&1 | tee "${LOG_FILE}"
exit_code=${PIPESTATUS[0]}
set -e

echo ""
log "Results saved to ${LOG_FILE}"
echo ""

# Summary
total=$(grep -cE '^(ok|not ok) ' "${LOG_FILE}" || true)
passed=$(grep -cE '^ok ' "${LOG_FILE}" || true)
failed=$(grep -cE '^not ok ' "${LOG_FILE}" || true)
skipped=$(grep -cE '# skip' "${LOG_FILE}" || true)

log "Summary: ${passed} passed, ${failed} failed, ${skipped} skipped (${total} total)"

if [[ "$failed" -gt 0 ]]; then
    echo ""
    log "Failures:"
    grep -E '^not ok ' "${LOG_FILE}" | sed 's/^/  /'
fi

exit "$exit_code"
