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
#   kata-master   (2 CPU, 2GB, 20GB) — k3s server, MicroCeph, ceph-csi provisioner, tainted NoSchedule
#   kata-worker-1 (2 CPU, 4GB, 20GB) — k3s agent + CRI-O + kata-deploy (needs /dev/kvm)
#   kata-worker-2 (2 CPU, 4GB, 20GB) — k3s agent + CRI-O + kata-deploy (needs /dev/kvm)
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
KATA_DEPLOY_VERSION="3.28.0"
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
    MASTER_CPUS=2  MASTER_MEMORY="2G"  MASTER_DISK="10G"
    WORKER_NAMES=("kata-worker-1" "kata-worker-2")
    WORKER_CPUS=2  WORKER_MEMORY="4G"  WORKER_DISK="10G"
fi

ALL_VMS=("$MASTER_NAME" "${WORKER_NAMES[@]}")

# --- helpers ---

log()     { echo "==> $*"; }
vm_exec() { multipass exec "$1" -- sudo bash -c "$2"; }

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

wait_for_k3s() {
    local name="$1"
    log "Waiting for k3s on $name..."
    for _ in $(seq 1 60); do
        if vm_exec "$name" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes &>/dev/null"; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: k3s on $name did not become ready" >&2
    exit 1
}

wait_for_pod() {
    local label="$1" ns="$2" timeout="${3:-300}"
    log "Waiting for pod $label in $ns (timeout ${timeout}s)..."
    vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl wait --for=condition=ready pod -l $label -n $ns --timeout=${timeout}s"
}

kubectl_master() {
    vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $1"
}

export_kubeconfig() {
    local master_ip
    master_ip=$(get_vm_ip "$MASTER_NAME")
    multipass exec "$MASTER_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml \
        | sed "s|127.0.0.1|${master_ip}|" > "$KUBECONFIG_HOST"
    log "Kubeconfig written to $KUBECONFIG_HOST"
}

# --- reusable install functions ---

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

install_k3s_server() {
    local name="$1"
    if vm_exec "$name" "command -v k3s &>/dev/null"; then
        log "[$name] k3s server already installed"
        return
    fi

    if [[ "$NUM_NODES" == "1" ]]; then
        # Single-node: server uses CRI-O
        log "[$name] Installing k3s server with CRI-O..."
        vm_exec "$name" "
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--container-runtime-endpoint unix:///var/run/crio/crio.sock' sh -
        "
    else
        # Multi-node: server uses default containerd (no kata workloads), writes kubeconfig readable
        log "[$name] Installing k3s server (containerd, tainted NoSchedule)..."
        vm_exec "$name" "
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--write-kubeconfig-mode 644 --node-taint node-role.kubernetes.io/control-plane:NoSchedule' sh -
        "
    fi
}

install_k3s_agent() {
    local name="$1" server_url="$2" token="$3"
    if vm_exec "$name" "systemctl is-active k3s-agent &>/dev/null"; then
        log "[$name] k3s agent already running"
        return
    fi
    log "[$name] Installing k3s agent..."
    vm_exec "$name" "
        curl -sfL https://get.k3s.io | K3S_URL='${server_url}' K3S_TOKEN='${token}' \
            INSTALL_K3S_EXEC='--container-runtime-endpoint unix:///var/run/crio/crio.sock' sh -
    "
}

setup_cni_symlinks() {
    local name="$1"
    log "[$name] Ensuring CNI symlinks..."
    vm_exec "$name" "
        mkdir -p /etc/cni/net.d /opt/cni/bin
        if [ ! -e /etc/cni/net.d/10-flannel.conflist ]; then
            ln -sf /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conflist
        fi
        for bin in /var/lib/rancher/k3s/data/current/bin/*; do
            name_bin=\$(basename \"\$bin\")
            [ ! -e /opt/cni/bin/\"\$name_bin\" ] && ln -sf \"\$bin\" /opt/cni/bin/\"\$name_bin\" || true
        done
    "
}

install_yq_vm() {
    local name="$1"
    if vm_exec "$name" "command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q '${YQ_VERSION}'"; then
        log "[$name] yq ${YQ_VERSION} already installed"
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
    # yq on host
    if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q "${YQ_VERSION}"; then
        log "[host] yq ${YQ_VERSION} already installed"
    else
        log "[host] Installing yq ${YQ_VERSION} (~/.local/bin)..."
        mkdir -p "${HOME}/.local/bin"
        curl -fsSL -o "${HOME}/.local/bin/yq" \
            "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
        chmod +x "${HOME}/.local/bin/yq"
    fi

    # bats on host
    if ! command -v bats &>/dev/null; then
        log "[host] WARNING: bats not found. Install via: sudo apt-get install bats"
    fi

    # helm on host
    if ! command -v helm &>/dev/null; then
        log "[host] WARNING: helm not found. Install via: snap install helm --classic"
    fi
}

label_kata_node() {
    local node_name="$1"
    log "Labeling $node_name for kata..."
    kubectl_master "label node $node_name katacontainers.io/kata-runtime=true --overwrite"
}

install_kata_deploy() {
    if vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm status kata-deploy -n kube-system &>/dev/null"; then
        log "kata-deploy already installed"
        return
    fi

    log "Installing kata-deploy ${KATA_DEPLOY_VERSION} via helm..."

    # Build helm dependencies on host if needed
    if [ ! -d "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy/charts" ]; then
        (cd "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy" && helm dependency build)
    fi

    # Copy chart to master and install
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

    wait_for_pod "app=kata-deploy" "kube-system" 600
}

add_kata_runtime_alias() {
    # Add 'kata' CRI-O runtime on a given node
    local name="$1"
    log "[$name] Ensuring 'kata' CRI-O runtime..."
    vm_exec "$name" "
        if ! grep -q '\\[crio.runtime.runtimes.kata\\]' /etc/crio/crio.conf.d/99-kata-deploy 2>/dev/null; then
            cat >> /etc/crio/crio.conf.d/99-kata-deploy <<'CRIO_EOF'

[crio.runtime.runtimes.kata]
	runtime_path = \"/opt/kata/runtime-rs/bin/containerd-shim-kata-v2\"
	runtime_type = \"vm\"
	runtime_root = \"/run/vc\"
	runtime_config_path = \"/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-coco-dev-runtime-rs.toml\"
	privileged_without_host_devices = true
	runtime_pull_image = true
CRIO_EOF
            systemctl restart crio
        fi
    "

    # Create kata RuntimeClass (only once, on master)
    kubectl_master "get runtimeclass kata &>/dev/null 2>&1 || \
        kubectl apply -f - <<'RC_EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
RC_EOF"
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

        log "[$name] Creating ${MICROCEPH_OSD_COUNT} OSD disks (${MICROCEPH_OSD_SIZE} each)..."
        for _ in $(seq 1 "$MICROCEPH_OSD_COUNT"); do
            vm_exec "$name" "microceph disk add loop,${MICROCEPH_OSD_SIZE},1"
        done
    fi

    # Create pool and user
    if ! vm_exec "$name" "ceph osd pool ls | grep -q kubernetes"; then
        log "[$name] Creating ceph pool 'kubernetes'..."
        vm_exec "$name" "
            ceph osd pool create kubernetes 32
            ceph osd pool application enable kubernetes rbd
        "
    fi

    if ! vm_exec "$name" "ceph auth get client.kubernetes &>/dev/null"; then
        log "[$name] Creating ceph user 'kubernetes'..."
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

    # Ceph runs on master in both single and multi-node
    local ceph_node="$MASTER_NAME"
    local ceph_fsid ceph_mon_ip ceph_key
    ceph_fsid=$(vm_exec "$ceph_node" "ceph fsid")
    ceph_mon_ip=$(get_vm_ip "$ceph_node")
    ceph_key=$(vm_exec "$ceph_node" "ceph auth get-key client.kubernetes")

    vm_exec "$MASTER_NAME" "
        KUBECONFIG=/etc/rancher/k3s/k3s.yaml
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

    wait_for_pod "app=ceph-csi-rbd-nodeplugin" "ceph-csi" 300
    wait_for_pod "app=ceph-csi-rbd-provisioner" "ceph-csi" 300
}

install_rbd_on_worker() {
    local name="$1"
    log "[$name] Ensuring rbd kernel module and ceph-common..."
    vm_exec "$name" "
        modprobe rbd 2>/dev/null || true
        if ! command -v rbd &>/dev/null; then
            apt-get update -qq
            apt-get install -y -qq ceph-common > /dev/null
        fi
    "
}

# ============================================================
# MAIN
# ============================================================

if [[ "$NUM_NODES" == "1" ]]; then

    # --- Single-node setup (backward compatible) ---

    ensure_vm "$MASTER_NAME" "$MASTER_CPUS" "$MASTER_MEMORY" "$MASTER_DISK"
    install_crio "$MASTER_NAME"
    install_k3s_server "$MASTER_NAME"
    wait_for_k3s "$MASTER_NAME"
    setup_cni_symlinks "$MASTER_NAME"
    install_host_tools
    install_yq_vm "$MASTER_NAME"
    install_helm_vm "$MASTER_NAME"
    label_kata_node "$MASTER_NAME"
    install_kata_deploy
    add_kata_runtime_alias "$MASTER_NAME"

    if [[ "$INSTALL_CEPH" == "true" ]]; then
        install_microceph "$MASTER_NAME"
        install_ceph_csi
    fi

    export_kubeconfig

else

    # --- 3-node setup ---

    log "Setting up 3-node cluster..."

    # Step 1: Launch all VMs
    ensure_vm "$MASTER_NAME" "$MASTER_CPUS" "$MASTER_MEMORY" "$MASTER_DISK"
    for w in "${WORKER_NAMES[@]}"; do
        ensure_vm "$w" "$WORKER_CPUS" "$WORKER_MEMORY" "$WORKER_DISK"
    done

    # Step 2: Master — k3s server (containerd, no CRI-O needed)
    install_k3s_server "$MASTER_NAME"
    wait_for_k3s "$MASTER_NAME"
    install_helm_vm "$MASTER_NAME"
    install_yq_vm "$MASTER_NAME"

    # Get join token and server URL
    K3S_TOKEN=$(vm_exec "$MASTER_NAME" "cat /var/lib/rancher/k3s/server/node-token")
    MASTER_IP=$(get_vm_ip "$MASTER_NAME")
    K3S_URL="https://${MASTER_IP}:6443"

    # Step 3: Workers — CRI-O + k3s agent
    for w in "${WORKER_NAMES[@]}"; do
        install_crio "$w"
        install_k3s_agent "$w" "$K3S_URL" "$K3S_TOKEN"
        setup_cni_symlinks "$w"
        install_yq_vm "$w"
    done

    # Step 4: Wait for all nodes to be ready
    log "Waiting for all nodes to be ready..."
    for _ in $(seq 1 60); do
        ready_count=$(vm_exec "$MASTER_NAME" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true")
        if [[ "$ready_count" -ge 3 ]]; then
            break
        fi
        sleep 5
    done
    kubectl_master "get nodes"

    # Step 5: Label worker nodes for kata
    for w in "${WORKER_NAMES[@]}"; do
        label_kata_node "$w"
    done

    # Step 6: Install kata-deploy (DaemonSet runs on workers only — master is tainted)
    install_kata_deploy

    # Step 7: Add kata runtime alias on each worker
    for w in "${WORKER_NAMES[@]}"; do
        add_kata_runtime_alias "$w"
    done

    # Step 8: Host tools
    install_host_tools

    # Step 9: MicroCeph on master, rbd on workers
    if [[ "$INSTALL_CEPH" == "true" ]]; then
        install_microceph "$MASTER_NAME"
        for w in "${WORKER_NAMES[@]}"; do
            install_rbd_on_worker "$w"
        done
        install_ceph_csi
    fi

    export_kubeconfig

fi

# --- done ---

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
