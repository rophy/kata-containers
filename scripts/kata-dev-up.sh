#!/usr/bin/env bash
#
# Provision the kata-dev multipass VM with k3s + CRI-O + kata-deploy + MicroCeph + ceph-csi.
# Idempotent: safe to re-run on an existing VM (skips already-completed steps).
#
# Usage:
#   ./scripts/kata-dev-up.sh            # full setup
#   ./scripts/kata-dev-up.sh --no-ceph  # skip MicroCeph + ceph-csi
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_NAME="kata-dev"
VM_CPUS=4
VM_MEMORY=8G
VM_DISK=50G
VM_IMAGE="24.04"

CRIO_VERSION="v1.33"
YQ_VERSION="v4.44.5"
KATA_DEPLOY_VERSION="3.28.0"
CEPH_CSI_CHART_VERSION="3.16.2"
MICROCEPH_OSD_SIZE="2G"
MICROCEPH_OSD_COUNT=3

INSTALL_CEPH=true
if [[ "${1:-}" == "--no-ceph" ]]; then
    INSTALL_CEPH=false
fi

KUBECONFIG_HOST="/tmp/kata-dev-kubeconfig.yaml"

# --- helpers ---

log() { echo "==> $*"; }
vm()  { multipass exec "$VM_NAME" -- "$@"; }
vm_sudo() { multipass exec "$VM_NAME" -- sudo bash -c "$1"; }

wait_for_k3s() {
    log "Waiting for k3s to be ready..."
    for i in $(seq 1 60); do
        if vm_sudo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes &>/dev/null"; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: k3s did not become ready" >&2
    exit 1
}

wait_for_pod() {
    local label="$1" ns="$2" timeout="${3:-300}"
    log "Waiting for pod $label in $ns (timeout ${timeout}s)..."
    vm_sudo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl wait --for=condition=ready pod -l $label -n $ns --timeout=${timeout}s"
}

export_kubeconfig() {
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f3)
    multipass exec "$VM_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml \
        | sed "s|127.0.0.1|${vm_ip}|" > "$KUBECONFIG_HOST"
    log "Kubeconfig written to $KUBECONFIG_HOST"
}

# --- step 1: launch VM ---

if multipass info "$VM_NAME" &>/dev/null; then
    state=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f2)
    if [[ "$state" == "Running" ]]; then
        log "VM $VM_NAME already running"
    else
        log "Starting VM $VM_NAME..."
        multipass start "$VM_NAME"
    fi
else
    log "Launching VM $VM_NAME ($VM_CPUS CPU, $VM_MEMORY RAM, $VM_DISK disk, $VM_IMAGE)..."
    multipass launch "$VM_IMAGE" \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --disk "$VM_DISK"
fi

# --- step 2: install CRI-O ---

if vm_sudo "command -v crio &>/dev/null"; then
    log "CRI-O already installed"
else
    log "Installing CRI-O ${CRIO_VERSION}..."
    vm_sudo "
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

# --- step 3: install k3s with CRI-O ---

if vm_sudo "command -v k3s &>/dev/null"; then
    log "k3s already installed"
else
    log "Installing k3s with CRI-O..."
    vm_sudo "
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--container-runtime-endpoint unix:///var/run/crio/crio.sock' sh -
    "
fi

wait_for_k3s

# --- step 4: CNI symlinks (k3s flannel -> standard paths) ---

log "Ensuring CNI symlinks..."
vm_sudo "
    mkdir -p /etc/cni/net.d /opt/cni/bin
    # Symlink flannel config if not already linked
    if [ ! -e /etc/cni/net.d/10-flannel.conflist ]; then
        ln -sf /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conflist
    fi
    # Symlink CNI binaries
    for bin in /var/lib/rancher/k3s/data/current/bin/*; do
        name=\$(basename \"\$bin\")
        [ ! -e /opt/cni/bin/\"\$name\" ] && ln -sf \"\$bin\" /opt/cni/bin/\"\$name\" || true
    done
"

# --- step 5: install tools ---

# yq (mikefarah) - needed on HOST for BATS tests (set_node, policy generation)
if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q "${YQ_VERSION}"; then
    log "yq ${YQ_VERSION} already installed on host"
else
    log "Installing yq ${YQ_VERSION} on host (~/.local/bin)..."
    mkdir -p "${HOME}/.local/bin"
    curl -fsSL -o "${HOME}/.local/bin/yq" \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
    chmod +x "${HOME}/.local/bin/yq"
fi

# yq also inside VM (for any in-VM scripts)
if vm_sudo "command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q '${YQ_VERSION}'"; then
    log "yq ${YQ_VERSION} already installed in VM"
else
    log "Installing yq ${YQ_VERSION} in VM..."
    vm_sudo "
        curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64
        chmod +x /usr/local/bin/yq
    "
fi

# bats - needed on HOST for running tests
if command -v bats &>/dev/null; then
    log "bats already installed on host"
else
    log "Installing bats on host..."
    echo "WARNING: bats not found. Install via: sudo apt-get install bats"
fi

# helm - needed on HOST for chart operations
if command -v helm &>/dev/null; then
    log "helm already installed on host"
else
    log "Installing helm on host..."
    echo "WARNING: helm not found. Install via: snap install helm --classic"
fi

# helm inside VM (for helm status checks and installs)
if vm_sudo "command -v helm &>/dev/null"; then
    log "helm already installed in VM"
else
    log "Installing helm in VM..."
    vm_sudo "snap install helm --classic"
fi

# --- step 6: label node for kata ---

log "Labeling node for kata..."
vm_sudo "
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    kubectl label node $VM_NAME katacontainers.io/kata-runtime=true --overwrite
"

# --- step 7: install kata-deploy via helm ---

if vm_sudo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm status kata-deploy -n kube-system &>/dev/null"; then
    log "kata-deploy already installed"
else
    log "Installing kata-deploy ${KATA_DEPLOY_VERSION} via helm..."

    # Build helm dependencies if needed
    if [ ! -d "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy/charts" ]; then
        (cd "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy" && helm dependency build)
    fi

    # Copy chart to VM and install
    multipass transfer -r "${REPO_ROOT}/tools/packaging/kata-deploy/helm-chart/kata-deploy" "${VM_NAME}:/tmp/kata-deploy-chart"

    vm_sudo "
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
fi

# --- step 8: add 'kata' runtime alias (runtime-rs, same config as qemu-coco-dev-rs) ---

log "Ensuring 'kata' CRI-O runtime and RuntimeClass..."
vm_sudo "
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Add kata runtime to CRI-O if not present
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

    # Create kata RuntimeClass if not present
    kubectl get runtimeclass kata &>/dev/null 2>&1 || \
    kubectl apply -f - <<'RC_EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
RC_EOF
"

# --- step 9: MicroCeph + ceph-csi (optional) ---

if [[ "$INSTALL_CEPH" == "true" ]]; then
    if vm_sudo "command -v microceph &>/dev/null"; then
        log "MicroCeph already installed"
    else
        log "Installing MicroCeph..."
        vm_sudo "
            snap install microceph
            microceph cluster bootstrap
            # Wait for cluster to be ready
            sleep 5
        "

        log "Creating ${MICROCEPH_OSD_COUNT} OSD disks (${MICROCEPH_OSD_SIZE} each)..."
        for i in $(seq 1 "$MICROCEPH_OSD_COUNT"); do
            vm_sudo "microceph disk add loop,${MICROCEPH_OSD_SIZE},1"
        done
    fi

    # Create ceph pool and user for k8s
    if ! vm_sudo "ceph osd pool ls | grep -q kubernetes"; then
        log "Creating ceph pool 'kubernetes'..."
        vm_sudo "
            ceph osd pool create kubernetes 32
            ceph osd pool application enable kubernetes rbd
        "
    fi

    if ! vm_sudo "ceph auth get client.kubernetes &>/dev/null"; then
        log "Creating ceph user 'kubernetes'..."
        vm_sudo "
            ceph auth get-or-create client.kubernetes \
                mon 'profile rbd' \
                osd 'profile rbd pool=kubernetes' \
                mgr 'profile rbd pool=kubernetes'
        "
    fi

    # Install ceph-csi via helm
    if vm_sudo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm status ceph-csi-rbd -n ceph-csi &>/dev/null"; then
        log "ceph-csi-rbd already installed"
    else
        log "Installing ceph-csi-rbd..."

        CEPH_FSID=$(vm_sudo "ceph fsid")
        CEPH_MON_IP=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d, -f3)
        CEPH_KEY=$(vm_sudo "ceph auth get-key client.kubernetes")

        vm_sudo "
            KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            helm repo add ceph-csi https://ceph.github.io/csi-charts
            helm repo update
            kubectl create namespace ceph-csi --dry-run=client -o yaml | kubectl apply -f -
            helm install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
                --namespace ceph-csi \
                --version ${CEPH_CSI_CHART_VERSION} \
                --set csiConfig[0].clusterID=${CEPH_FSID} \
                --set csiConfig[0].monitors[0]=${CEPH_MON_IP}:6789 \
                --set secret.create=true \
                --set secret.userID=kubernetes \
                --set secret.userKey=${CEPH_KEY} \
                --set storageClass.create=true \
                --set storageClass.name=ceph-rbd \
                --set storageClass.clusterID=${CEPH_FSID} \
                --set storageClass.pool=kubernetes \
                --set provisioner.provisioner.image.repository=registry.k8s.io/sig-storage/csi-provisioner \
                --set nodeplugin.registrar.image.repository=registry.k8s.io/sig-storage/csi-node-driver-registrar
        "

        wait_for_pod "app=ceph-csi-rbd-nodeplugin" "ceph-csi" 300
        wait_for_pod "app=ceph-csi-rbd-provisioner" "ceph-csi" 300
    fi
fi

# --- step 10: export kubeconfig ---

export_kubeconfig

# --- done ---

log "kata-dev VM is ready!"
log ""
log "  KUBECONFIG=$KUBECONFIG_HOST"
log "  kubectl --context default get runtimeclass"
log ""
log "To run BATS tests:"
log "  cd tests/integration/kubernetes"
log "  KUBECONFIG=$KUBECONFIG_HOST KATA_HYPERVISOR=qemu KUBERNETES=k3s bash setup.sh"
log "  KUBECONFIG=$KUBECONFIG_HOST KATA_HYPERVISOR=qemu KUBERNETES=k3s bats k8s-env.bats"
