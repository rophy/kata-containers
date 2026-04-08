#!/usr/bin/env bash
#
# Tear down kata-dev test environment VMs.
#
# Usage:
#   ./scripts/kata-dev-down.sh           # stop all kata VMs (preserves state)
#   ./scripts/kata-dev-down.sh --delete  # delete all kata VMs entirely
#
set -euo pipefail

KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

# All possible VM names across single-node and multi-node setups
ALL_VMS=("kata-dev" "kata-master" "kata-worker-1" "kata-worker-2")

DELETE=false
if [[ "${1:-}" == "--delete" ]]; then
    DELETE=true
fi

log() { echo "==> $*"; }

found_any=false

for vm in "${ALL_VMS[@]}"; do
    if ! multipass info "$vm" &>/dev/null; then
        continue
    fi
    found_any=true

    if [[ "$DELETE" == "true" ]]; then
        log "Deleting $vm..."
        multipass delete "$vm"
    else
        state=$(multipass info "$vm" --format csv | tail -1 | cut -d, -f2)
        if [[ "$state" == "Running" ]]; then
            log "Stopping $vm..."
            multipass stop "$vm"
        else
            log "$vm is already stopped"
        fi
    fi
done

if [[ "$DELETE" == "true" && "$found_any" == "true" ]]; then
    multipass purge
    log "All kata VMs deleted and purged"
elif [[ "$found_any" == "false" ]]; then
    log "No kata VMs found"
fi

# Clean up host kubeconfig
if [ -f "$KUBECONFIG_HOST" ]; then
    rm -f "$KUBECONFIG_HOST"
    log "Removed $KUBECONFIG_HOST"
fi
