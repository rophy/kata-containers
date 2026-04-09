#!/usr/bin/env bash
#
# Tear down kata-dev test environment VMs.
#
# Usage:
#   ./scripts/kata-dev-down.sh           # stop all kata VMs (preserves state)
#   ./scripts/kata-dev-down.sh --delete  # delete all kata VMs entirely
#
set -uo pipefail
# Note: no -e — we want to continue deleting remaining VMs if one fails

KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

# All possible VM names across single-node and multi-node setups
ALL_VMS=("kata-dev" "kata-master" "kata-worker-1" "kata-worker-2")

DELETE=false
if [[ "${1:-}" == "--delete" ]]; then
    DELETE=true
fi

log() { echo "==> $*"; }

found_any=false
had_error=false

for vm in "${ALL_VMS[@]}"; do
    if ! multipass info "$vm" &>/dev/null; then
        continue
    fi
    found_any=true

    if [[ "$DELETE" == "true" ]]; then
        # Stop first (more reliable than delete on a running VM)
        state=$(multipass info "$vm" --format csv | tail -1 | cut -d, -f2)
        if [[ "$state" == "Running" ]]; then
            log "Stopping $vm..."
            multipass stop "$vm" --force || true
        fi
        log "Deleting $vm..."
        if ! multipass delete "$vm"; then
            log "WARNING: failed to delete $vm, will retry with force"
            multipass delete "$vm" --purge 2>/dev/null || true
            had_error=true
        fi
    else
        state=$(multipass info "$vm" --format csv | tail -1 | cut -d, -f2)
        if [[ "$state" == "Running" ]]; then
            log "Stopping $vm..."
            multipass stop "$vm" || { log "WARNING: failed to stop $vm"; had_error=true; }
        else
            log "$vm is already stopped"
        fi
    fi
done

if [[ "$DELETE" == "true" && "$found_any" == "true" ]]; then
    multipass purge 2>/dev/null || true
    log "All kata VMs deleted and purged"
elif [[ "$found_any" == "false" ]]; then
    log "No kata VMs found"
fi

# Clean up host kubeconfig
if [ -f "$KUBECONFIG_HOST" ]; then
    rm -f "$KUBECONFIG_HOST"
    log "Removed $KUBECONFIG_HOST"
fi

if [[ "$had_error" == "true" ]]; then
    log "Some operations had warnings — check output above"
    exit 1
fi
