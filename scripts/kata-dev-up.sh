#!/usr/bin/env bash
#
# Provision kata-dev test environment with k3s + CRI-O + kata-deploy + MicroCeph + ceph-csi.
# Idempotent: safe to re-run on existing VMs (skips already-completed steps).
#
# Usage:
#   ./scripts/kata-dev-up.sh                # single-node (default)
#   ./scripts/kata-dev-up.sh --nodes 3      # 3-node cluster for failover testing
#   ./scripts/kata-dev-up.sh --no-ceph      # skip MicroCeph + ceph-csi
#
# Single-node layout (kata-dev):
#   - k3s server + CRI-O + kata-deploy + MicroCeph + ceph-csi (all-in-one)
#
# 3-node layout:
#   kata-master   (2 CPU, 4GB, 10GB) — k3s server (containerd), MicroCeph, tainted NoSchedule
#   kata-worker-1 (2 CPU, 4GB, 30GB) — k3s agent + CRI-O + kata-deploy (needs /dev/kvm)
#   kata-worker-2 (2 CPU, 4GB, 30GB) — k3s agent + CRI-O + kata-deploy (needs /dev/kvm)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- defaults ---

NUM_NODES=1
INSTALL_CEPH=true
VM_IMAGE="24.04"

CRIO_VERSION="v1.33"
YQ_VERSION="v4.44.5"
CEPH_CSI_CHART_VERSION="3.16.2"
MICROCEPH_OSD_SIZE="2G"
MICROCEPH_OSD_COUNT=3

KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

# --- parse args ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)   NUM_NODES="$2"; shift 2 ;;
        --no-ceph) INSTALL_CEPH=false; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "$NUM_NODES" != "1" && "$NUM_NODES" != "3" ]]; then
    echo "ERROR: --nodes must be 1 or 3" >&2
    exit 1
fi

# --- VM sizing ---

if [[ "$NUM_NODES" == "1" ]]; then
    MASTER_NAME="kata-dev"
    MASTER_CPUS=4  MASTER_MEMORY="8G"  MASTER_DISK="50G"
    WORKER_NAMES=()
else
    MASTER_NAME="kata-master"
    MASTER_CPUS=2  MASTER_MEMORY="4G"  MASTER_DISK="10G"
    WORKER_NAMES=("kata-worker-1" "kata-worker-2")
    WORKER_CPUS=2  WORKER_MEMORY="4G"  WORKER_DISK="30G"
fi

# --- helpers ---

log() { echo "==> $*"; }

# Run a command on a VM as root.
# DEBIAN_FRONTEND=noninteractive prevents needrestart/dpkg-preconfigure hangs.
vm_exec() {
    local name="$1"; shift
    multipass exec "$name" -- sudo bash -c "export DEBIAN_FRONTEND=noninteractive; $1"
}

get_vm_ip() {
    multipass info "$1" --format csv | tail -1 | cut -d, -f3
}

ensure_vm() {
    local name="$1" cpus="$2" memory="$3" disk="$4"
    if multipass info "$name" &>/dev/null; then
        local state
        state=$(multipass info "$name" --format csv | tail -1 | cut -d, -f2)
        if [[ "$state" == "Running" ]]; then
            log "VM $name already running"
        else
            log "Starting VM $name..."
            multipass start "$name"
        fi
    else
        log "Launching VM $name ($cpus CPU, $memory RAM, $disk disk)..."
        multipass launch "$VM_IMAGE" \
            --name "$name" \
            --cpus "$cpus" \
            --memory "$memory" \
            --disk "$disk"
    fi
}

kubectl_master() {
    vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $1"
}

wait_for_k3s() {
    local name="$1"
    log "Waiting for k3s API on $name..."
    for _ in $(seq 1 60); do
        if vm_exec "$name" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes &>/dev/null"; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: k3s on $name did not become ready within 5 minutes" >&2
    exit 1
}

wait_for_node_ready() {
    local node_name="$1" timeout="${2:-120}"
    log "Waiting for node $node_name to be Ready (timeout ${timeout}s)..."
    for _ in $(seq 1 "$((timeout / 5))"); do
        if kubectl_master "get node $node_name -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | grep -q True; then
            log "Node $node_name is Ready"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: Node $node_name did not become Ready within ${timeout}s" >&2
    echo "Diagnostics:" >&2
    kubectl_master "describe node $node_name" 2>&1 | grep -A5 'Conditions:' >&2
    exit 1
}

wait_for_pod() {
    local label="$1" ns="$2" timeout="${3:-300}"
    log "Waiting for pod $label in $ns (timeout ${timeout}s)..."
    kubectl_master "wait --for=condition=ready pod -l $label -n $ns --timeout=${timeout}s"
}

export_kubeconfig() {
    local master_ip
    master_ip=$(get_vm_ip "$MASTER_NAME")
    multipass exec "$MASTER_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml \
        | sed "s|127.0.0.1|${master_ip}|" > "$KUBECONFIG_HOST"
    log "Kubeconfig written to $KUBECONFIG_HOST"
}

# --- reusable install functions ---

# Disable needrestart on Ubuntu 24.04 so apt never hangs waiting for input.
disable_needrestart() {
    local name="$1"
    vm_exec "$name" "
        if [ -f /etc/needrestart/needrestart.conf ]; then
            sed -i \"s/#\\\$nrconf{restart} = 'i';/\\\$nrconf{restart} = 'a';/\" /etc/needrestart/needrestart.conf
        fi
    "
}

install_crio() {
    local name="$1"
    if vm_exec "$name" "command -v crio &>/dev/null"; then
        log "[$name] CRI-O already installed"
    else
        log "[$name] Installing CRI-O ${CRIO_VERSION}..."
        vm_exec "$name" "
            apt-get update -qq
            apt-get install -y -qq software-properties-common curl gpg > /dev/null
            curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key \
                | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
            echo 'deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /' \
                > /etc/apt/sources.list.d/cri-o.list
            apt-get update -qq
            apt-get install -y -qq cri-o > /dev/null
            systemctl enable --now crio
        "
    fi
}

# kata-deploy reads /etc/containerd/config.toml even on CRI-O-only nodes.
# Without this stub, kata-deploy crashes with "No such file or directory".
create_containerd_stub() {
    local name="$1"
    vm_exec "$name" "
        if [ ! -f /etc/containerd/config.toml ]; then
            mkdir -p /etc/containerd
            cat > /etc/containerd/config.toml <<'CTRD'
version = 2
[plugins]
  [plugins.\"io.containerd.grpc.v1.cri\"]
    [plugins.\"io.containerd.grpc.v1.cri\".containerd]
      default_runtime_name = \"runc\"
CTRD
        fi
    "
}

install_k3s_server() {
    local name="$1"
    if vm_exec "$name" "command -v k3s &>/dev/null"; then
        log "[$name] k3s server already installed"
        return
    fi
    if [[ "$NUM_NODES" == "1" ]]; then
        log "[$name] Installing k3s server with CRI-O..."
        vm_exec "$name" "
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--container-runtime-endpoint unix:///var/run/crio/crio.sock' sh -
        "
    else
        log "[$name] Installing k3s server (tainted NoSchedule)..."
        vm_exec "$name" "
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--write-kubeconfig-mode 644 --node-taint node-role.kubernetes.io/control-plane:NoSchedule' sh -
        "
    fi
}

# Install k3s agent WITHOUT starting it. The k3s install script runs systemctl start
# which blocks forever (Type=notify) because the agent needs CNI to report Ready.
# We start the agent ourselves after CNI is set up.
install_k3s_agent() {
    local name="$1" server_url="$2" token="$3"
    if vm_exec "$name" "systemctl list-unit-files k3s-agent.service &>/dev/null"; then
        log "[$name] k3s agent already installed"
        return
    fi
    log "[$name] Installing k3s agent (skip start)..."
    vm_exec "$name" "
        curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true K3S_URL='${server_url}' K3S_TOKEN='${token}' \
            INSTALL_K3S_EXEC='--container-runtime-endpoint unix:///var/run/crio/crio.sock' sh -
    "
}

# Start k3s agent and set up CNI.
# The agent is installed with INSTALL_K3S_SKIP_START, so we:
# 1. Start the agent in the background (don't block on systemd notify)
# 2. Wait for the agent to create the flannel CNI config
# 3. Symlink it to /etc/cni/net.d/ so CRI-O can see it
# Once CRI-O sees CNI, the agent reports Ready and systemd marks it active.
start_agent_and_setup_cni() {
    local name="$1"
    log "[$name] Starting k3s agent and setting up CNI..."
    vm_exec "$name" "
        # Start agent (don't wait — it blocks until Ready)
        systemctl start k3s-agent &

        # Wait up to 120s for agent to create flannel config
        for i in \$(seq 1 120); do
            if [ -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist ]; then
                break
            fi
            sleep 1
        done
        if [ ! -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist ]; then
            echo 'ERROR: flannel config not created after 120s' >&2
            journalctl -u k3s-agent --no-pager -n 10 >&2
            exit 1
        fi

        # Symlink CNI config and binaries
        mkdir -p /etc/cni/net.d /opt/cni/bin
        ln -sf /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conflist
        for bin in /var/lib/rancher/k3s/data/current/bin/*; do
            bname=\$(basename \"\$bin\")
            [ ! -e /opt/cni/bin/\"\$bname\" ] && ln -sf \"\$bin\" /opt/cni/bin/\"\$bname\" || true
        done
    "
}

# Single-node: k3s server creates flannel config immediately (no wait needed)
setup_server_cni() {
    local name="$1"
    log "[$name] Setting up CNI symlinks..."
    vm_exec "$name" "
        mkdir -p /etc/cni/net.d /opt/cni/bin
        if [ ! -e /etc/cni/net.d/10-flannel.conflist ]; then
            ln -sf /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conflist
        fi
        for bin in /var/lib/rancher/k3s/data/current/bin/*; do
            bname=\$(basename \"\$bin\")
            [ ! -e /opt/cni/bin/\"\$bname\" ] && ln -sf \"\$bin\" /opt/cni/bin/\"\$bname\" || true
        done
    "
}

install_yq_vm() {
    local name="$1"
    if vm_exec "$name" "command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q '${YQ_VERSION}'"; then
        log "[$name] yq already installed"
    else
        log "[$name] Installing yq ${YQ_VERSION}..."
        vm_exec "$name" "
            curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64
            chmod +x /usr/local/bin/yq
        "
    fi
}

install_helm_vm() {
    local name="$1"
    if vm_exec "$name" "command -v helm &>/dev/null"; then
        log "[$name] helm already installed"
    else
        log "[$name] Installing helm..."
        vm_exec "$name" "snap install helm --classic"
    fi
}

install_host_tools() {
    if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q "${YQ_VERSION}"; then
        log "[host] yq ${YQ_VERSION} OK"
    else
        log "[host] Installing yq ${YQ_VERSION}..."
        mkdir -p "${HOME}/.local/bin"
        curl -fsSL -o "${HOME}/.local/bin/yq" \
            "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
        chmod +x "${HOME}/.local/bin/yq"
    fi
    command -v bats &>/dev/null || log "[host] WARNING: bats not found. Install via: sudo apt-get install bats"
    command -v helm &>/dev/null || log "[host] WARNING: helm not found. Install via: snap install helm --classic"
}

install_kata_deploy() {
    if kubectl_master "helm status kata-deploy -n kube-system &>/dev/null" 2>/dev/null; then
        log "kata-deploy already installed"
        return
    fi
    log "Installing kata-deploy via helm..."
    if [ ! -d "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy/charts" ]; then
        (cd "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy" && helm dependency build)
    fi
    multipass transfer -r "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy" "${MASTER_NAME}:/tmp/kata-deploy-chart"
    vm_exec "$MASTER_NAME" "
        KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
        helm install kata-deploy /tmp/kata-deploy-chart \
            --namespace kube-system \
            --set debug=true \
            --set shims.disableAll=true \
            --set shims.qemu-coco-dev.enabled=true \
            --set shims.qemu-coco-dev.crio.guestPull=true \
            --set shims.qemu-coco-dev.containerd.forceGuestPull=true \
            --set defaultShim.amd64=qemu-coco-dev \
            --set runtimeClasses.createDefault=true \
            --set runtimeClasses.defaultName=kata-qemu-coco-dev
        rm -rf /tmp/kata-deploy-chart
    "
    wait_for_pod "name=kata-deploy" "kube-system" 600
}

# Add 'kata' as a CRI-O runtime alias pointing to runtime-rs qemu-coco-dev config.
# Must run AFTER kata-deploy completes (kata-deploy writes 99-kata-deploy config file).
add_kata_runtime_alias() {
    local name="$1"
    log "[$name] Adding 'kata' CRI-O runtime..."
    vm_exec "$name" "
        # Retry loop: kata-deploy may still be writing the config file
        for attempt in 1 2 3; do
            if grep -q '\\[crio.runtime.runtimes.kata\\]' /etc/crio/crio.conf.d/99-kata-deploy 2>/dev/null; then
                break
            fi
            cat >> /etc/crio/crio.conf.d/99-kata-deploy <<'EOF'

[crio.runtime.runtimes.kata]
	runtime_path = \"/opt/kata/runtime-rs/bin/containerd-shim-kata-v2\"
	runtime_type = \"vm\"
	runtime_root = \"/run/vc\"
	runtime_config_path = \"/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-coco-dev-runtime-rs.toml\"
	privileged_without_host_devices = true
	runtime_pull_image = true
EOF
            # Verify append survived (kata-deploy may have overwritten)
            if grep -q '\\[crio.runtime.runtimes.kata\\]' /etc/crio/crio.conf.d/99-kata-deploy 2>/dev/null; then
                break
            fi
            echo 'kata runtime config was overwritten, retrying in 10s...' >&2
            sleep 10
        done
        systemctl restart crio
    "
    # Create RuntimeClass (idempotent)
    kubectl_master "get runtimeclass kata &>/dev/null 2>&1 || \
        kubectl apply -f - <<'RC'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
RC"
}

install_microceph() {
    local name="$1"
    if vm_exec "$name" "command -v microceph &>/dev/null"; then
        log "[$name] MicroCeph already installed"
    else
        log "[$name] Installing MicroCeph..."
        vm_exec "$name" "
            snap install microceph
            microceph cluster bootstrap
            sleep 5
        "
        log "[$name] Creating ${MICROCEPH_OSD_COUNT} OSD disks..."
        for _ in $(seq 1 "$MICROCEPH_OSD_COUNT"); do
            vm_exec "$name" "microceph disk add loop,${MICROCEPH_OSD_SIZE},1"
        done
    fi
    # Pool and user
    if ! vm_exec "$name" "ceph osd pool ls | grep -q kubernetes"; then
        log "[$name] Creating ceph pool..."
        vm_exec "$name" "
            ceph config set global mon_allow_pool_size_one true
            ceph config set global osd_pool_default_size 1
            ceph config set global osd_pool_default_min_size 1
            ceph osd pool create kubernetes 32
            ceph osd pool set kubernetes size 1 --yes-i-really-mean-it
            ceph osd pool set kubernetes min_size 1
            ceph osd pool application enable kubernetes rbd
        "
    fi
    if ! vm_exec "$name" "ceph auth get client.kubernetes &>/dev/null"; then
        log "[$name] Creating ceph user..."
        vm_exec "$name" "
            ceph auth get-or-create client.kubernetes \
                mon 'profile rbd' \
                osd 'profile rbd pool=kubernetes' \
                mgr 'profile rbd pool=kubernetes'
        "
    fi
}

install_ceph_csi() {
    if vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm status ceph-csi-rbd -n ceph-csi &>/dev/null"; then
        log "ceph-csi-rbd already installed"
        return
    fi
    log "Installing ceph-csi-rbd..."
    local ceph_node="$MASTER_NAME"
    local ceph_fsid ceph_mon_ip ceph_key
    ceph_fsid=$(vm_exec "$ceph_node" "ceph fsid")
    ceph_mon_ip=$(get_vm_ip "$ceph_node")
    ceph_key=$(vm_exec "$ceph_node" "ceph auth get-key client.kubernetes")

    vm_exec "$MASTER_NAME" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        helm repo add ceph-csi https://ceph.github.io/csi-charts
        helm repo update
        kubectl create namespace ceph-csi --dry-run=client -o yaml | kubectl apply -f -
        helm install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
            --namespace ceph-csi \
            --version ${CEPH_CSI_CHART_VERSION} \
            --set csiConfig[0].clusterID=${ceph_fsid} \
            --set csiConfig[0].monitors[0]=${ceph_mon_ip}:6789 \
            --set secret.create=true \
            --set secret.userID=kubernetes \
            --set secret.userKey=${ceph_key} \
            --set storageClass.create=true \
            --set storageClass.name=ceph-rbd \
            --set storageClass.clusterID=${ceph_fsid} \
            --set storageClass.pool=kubernetes \
            --set provisioner.provisioner.image.repository=registry.k8s.io/sig-storage/csi-provisioner \
            --set nodeplugin.registrar.image.repository=registry.k8s.io/sig-storage/csi-node-driver-registrar
    "
    wait_for_pod "app=ceph-csi-rbd,component=nodeplugin" "ceph-csi" 600
}

install_rbd_on_worker() {
    local name="$1"
    log "[$name] Installing ceph-common..."
    vm_exec "$name" "
        if ! command -v rbd &>/dev/null; then
            apt-get update -qq
            apt-get install -y -qq ceph-common > /dev/null
        fi
        modprobe rbd 2>/dev/null || true
    "
}

# Full worker setup: disable needrestart, install CRI-O, containerd stub, k3s agent,
# wait for CNI, then install tools. Designed to run in parallel for multiple workers.
provision_worker() {
    local name="$1" server_url="$2" token="$3"
    disable_needrestart "$name"
    install_crio "$name"
    create_containerd_stub "$name"
    install_k3s_agent "$name" "$server_url" "$token"
    start_agent_and_setup_cni "$name"
    install_yq_vm "$name"
    if [[ "$INSTALL_CEPH" == "true" ]]; then
        install_rbd_on_worker "$name"
    fi
    log "[$name] Worker provisioning complete"
}

# ============================================================
# MAIN
# ============================================================

if [[ "$NUM_NODES" == "1" ]]; then

    # --- Single-node setup ---
    ensure_vm "$MASTER_NAME" "$MASTER_CPUS" "$MASTER_MEMORY" "$MASTER_DISK"
    disable_needrestart "$MASTER_NAME"
    install_crio "$MASTER_NAME"
    install_k3s_server "$MASTER_NAME"
    wait_for_k3s "$MASTER_NAME"
    setup_server_cni "$MASTER_NAME"
    install_host_tools
    install_yq_vm "$MASTER_NAME"
    install_helm_vm "$MASTER_NAME"
    kubectl_master "label node $MASTER_NAME katacontainers.io/kata-runtime=true --overwrite"
    install_kata_deploy
    add_kata_runtime_alias "$MASTER_NAME"
    if [[ "$INSTALL_CEPH" == "true" ]]; then
        install_microceph "$MASTER_NAME"
        install_ceph_csi
    fi

else

    # --- 3-node setup ---
    log "Setting up 3-node cluster..."

    # Step 1: Launch all VMs
    ensure_vm "$MASTER_NAME" "$MASTER_CPUS" "$MASTER_MEMORY" "$MASTER_DISK"
    for w in "${WORKER_NAMES[@]}"; do
        ensure_vm "$w" "$WORKER_CPUS" "$WORKER_MEMORY" "$WORKER_DISK"
    done

    # Step 2: Master — k3s server
    disable_needrestart "$MASTER_NAME"
    install_k3s_server "$MASTER_NAME"
    wait_for_k3s "$MASTER_NAME"
    install_helm_vm "$MASTER_NAME"
    install_yq_vm "$MASTER_NAME"

    # Step 3: Get join credentials
    K3S_TOKEN=$(vm_exec "$MASTER_NAME" "cat /var/lib/rancher/k3s/server/node-token")
    MASTER_IP=$(get_vm_ip "$MASTER_NAME")
    K3S_URL="https://${MASTER_IP}:6443"

    # Step 4: Provision workers in parallel
    for w in "${WORKER_NAMES[@]}"; do
        provision_worker "$w" "$K3S_URL" "$K3S_TOKEN" &
    done
    wait

    # Step 5: Wait for all worker nodes to be Ready
    for w in "${WORKER_NAMES[@]}"; do
        wait_for_node_ready "$w" 120
    done

    # Step 6: Label workers, install kata-deploy
    for w in "${WORKER_NAMES[@]}"; do
        kubectl_master "label node $w katacontainers.io/kata-runtime=true --overwrite"
    done
    install_kata_deploy

    # Step 7: Add kata runtime alias (AFTER kata-deploy writes CRI-O config)
    for w in "${WORKER_NAMES[@]}"; do
        add_kata_runtime_alias "$w"
    done

    # Step 8: Host tools
    install_host_tools

    # Step 9: MicroCeph + ceph-csi
    if [[ "$INSTALL_CEPH" == "true" ]]; then
        install_microceph "$MASTER_NAME"
        install_ceph_csi
    fi

fi

# --- Export kubeconfig ---

export_kubeconfig

# --- Done ---

log ""
log "Cluster is ready! (${NUM_NODES} node(s))"
log ""
log "  KUBECONFIG=$KUBECONFIG_HOST"
if [[ "$NUM_NODES" == "1" ]]; then
    log "  VM: $MASTER_NAME"
else
    log "  Master: $MASTER_NAME ($(get_vm_ip "$MASTER_NAME"))"
    for w in "${WORKER_NAMES[@]}"; do
        log "  Worker: $w ($(get_vm_ip "$w"))"
    done
fi
log ""
log "To run BATS tests:"
log "  ./scripts/kata-dev-test.sh"
