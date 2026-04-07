#!/usr/bin/env bash
#
# Tear down the kata-dev multipass VM.
#
# Usage:
#   ./scripts/kata-dev-down.sh          # stop the VM (preserves state)
#   ./scripts/kata-dev-down.sh --delete  # delete the VM entirely
#
set -euo pipefail

VM_NAME="kata-dev"
KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

log() { echo "==> $*"; }

if ! multipass info "$VM_NAME" &>/dev/null; then
    log "VM $VM_NAME does not exist"
    exit 0
fi

if [[ "${1:-}" == "--delete" ]]; then
    log "Deleting VM $VM_NAME..."
    multipass delete "$VM_NAME"
    multipass purge
    log "VM $VM_NAME deleted and purged"
else
    state=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f2)
    if [[ "$state" == "Running" ]]; then
        log "Stopping VM $VM_NAME..."
        multipass stop "$VM_NAME"
        log "VM $VM_NAME stopped (use --delete to remove entirely)"
    else
        log "VM $VM_NAME is already stopped"
    fi
fi

# Clean up host kubeconfig
if [ -f "$KUBECONFIG_HOST" ]; then
    rm -f "$KUBECONFIG_HOST"
    log "Removed $KUBECONFIG_HOST"
fi
