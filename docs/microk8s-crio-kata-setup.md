# MicroK8s with CRI-O and Kata Containers Setup Guide

This guide covers manual installation of Kata Containers on MicroK8s using CRI-O as the container runtime, running in a Multipass VM.

## Why CRI-O?

CRI-O is a lightweight container runtime specifically designed for Kubernetes. Unlike containerd which supports multiple use cases, CRI-O focuses solely on the Kubernetes CRI (Container Runtime Interface), making it a lean and purpose-built option.

## Prerequisites

**Host requirements:**
- Linux with KVM support (for nested virtualization in Multipass)
- Multipass installed (`snap install multipass`)
- ~2GB disk space for Kata release tarball

**Download Kata release to host (for reuse across VMs):**
```bash
cd /path/to/your/project
curl -L -o kata-static-3.26.0-amd64.tar.zst \
  https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-amd64.tar.zst
```

## Step 1: Create Multipass VM

```bash
multipass launch --name microk8s-crio --cpus 4 --memory 8G --disk 30G
```

**Note:** 8GB RAM minimum recommended. 4GB may cause OOM issues.

## Step 2: Install MicroK8s

```bash
multipass exec microk8s-crio -- sudo snap install microk8s --classic
multipass exec microk8s-crio -- sudo usermod -aG microk8s ubuntu
```

## Step 3: Install CRI-O

Install CRI-O from the official repository. Use a version matching your Kubernetes version (MicroK8s 1.33 = CRI-O 1.33):

```bash
multipass exec microk8s-crio -- bash -c '
# Install prerequisites
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg2

# Add CRI-O repository
CRIO_VERSION="v1.33"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/cri-o.list

# Install CRI-O
sudo apt-get update
sudo apt-get install -y cri-o
'
```

## Step 4: Configure CRI-O Storage (Critical for Kata)

**This step is critical and must be done BEFORE starting Kubernetes with CRI-O.**

Create the storage configuration:

```bash
multipass exec microk8s-crio -- sudo tee /etc/crio/crio.conf.d/00-storage.conf << 'EOF'
[crio]
storage_option = [
  "overlay.skip_mount_home=true",
]
EOF
```

> **Why is this needed?** Without this setting, CRI-O's overlay storage driver creates private bind mounts that prevent Kata's virtio-fs from properly sharing the container rootfs with the guest VM. This results in "file not found" errors for container entrypoints.

## Step 5: Start CRI-O

```bash
multipass exec microk8s-crio -- sudo systemctl enable crio
multipass exec microk8s-crio -- sudo systemctl start crio
```

## Step 6: Configure MicroK8s to Use CRI-O

Update kubelet to use CRI-O socket instead of containerd:

```bash
multipass exec microk8s-crio -- sudo bash -c '
sed -i "s|--container-runtime-endpoint=.*|--container-runtime-endpoint=unix:///var/run/crio/crio.sock|" \
  /var/snap/microk8s/current/args/kubelet
sed -i "s|--containerd=.*|--containerd=unix:///var/run/crio/crio.sock|" \
  /var/snap/microk8s/current/args/kubelet
'
```

Restart MicroK8s to apply changes:

```bash
multipass exec microk8s-crio -- sudo microk8s stop
multipass exec microk8s-crio -- sudo microk8s start
multipass exec microk8s-crio -- sudo microk8s status --wait-ready
```

Verify CRI-O is being used:

```bash
multipass exec microk8s-crio -- sudo microk8s kubectl get nodes -o wide
# Should show: CONTAINER-RUNTIME = cri-o://1.33.x
```

## Step 7: Disable MicroK8s containerd (Optional)

MicroK8s containerd will still be running even though kubelet is using CRI-O. To save resources, disable it:

```bash
multipass exec microk8s-crio -- sudo systemctl stop snap.microk8s.daemon-containerd
multipass exec microk8s-crio -- sudo systemctl disable snap.microk8s.daemon-containerd
```

> **Note:** This is optional but recommended. Having both container runtimes running wastes memory (~40MB for containerd).

## Step 8: Install Kata Containers

Copy and extract the Kata release:

```bash
# Copy from host to VM
multipass transfer kata-static-3.26.0-amd64.tar.zst microk8s-crio:/home/ubuntu/

# Install zstd and extract
multipass exec microk8s-crio -- sudo apt-get install -y zstd
multipass exec microk8s-crio -- sudo tar -C / -xvf /home/ubuntu/kata-static-3.26.0-amd64.tar.zst
```

Fix virtiofsd permissions:

```bash
multipass exec microk8s-crio -- sudo chmod +x /opt/kata/libexec/virtiofsd
```

## Step 9: Configure CRI-O for Kata Runtimes

Create the Kata runtime configuration:

```bash
multipass exec microk8s-crio -- sudo tee /etc/crio/crio.conf.d/50-kata.conf << 'EOF'
[crio.runtime.runtimes.kata]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration.toml"

[crio.runtime.runtimes.kata-qemu]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration-qemu.toml"

[crio.runtime.runtimes.kata-clh]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration-clh.toml"

[crio.runtime.runtimes.kata-fc]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"
EOF
```

## Step 10: Reboot VM

**A full reboot is required** for the storage configuration to take effect properly:

```bash
multipass restart microk8s-crio
multipass exec microk8s-crio -- sudo microk8s status --wait-ready
```

## Step 11: Create RuntimeClasses

```bash
multipass exec microk8s-crio -- sudo microk8s kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-clh
handler: kata-clh
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
handler: kata-fc
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
EOF
```

## Step 12: Verify Installation

```bash
# Check RuntimeClasses
multipass exec microk8s-crio -- sudo microk8s kubectl get runtimeclass

# Check container runtime
multipass exec microk8s-crio -- sudo microk8s kubectl get nodes -o wide
```

## Step 13: Test with a Pod

```bash
multipass exec microk8s-crio -- sudo microk8s kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-kata
spec:
  runtimeClassName: kata
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
EOF

# Wait for pod
multipass exec microk8s-crio -- sudo microk8s kubectl wait --for=condition=ready pod/test-kata --timeout=120s

# Verify different kernel (Kata guest vs host)
echo "Pod kernel:"
multipass exec microk8s-crio -- sudo microk8s kubectl exec test-kata -- uname -r

echo "Host kernel:"
multipass exec microk8s-crio -- uname -r
```

The pod kernel (e.g., `6.18.5`) should differ from the host kernel (e.g., `6.8.0-90-generic`), confirming the pod runs in a Kata VM.

## Available Runtimes

| RuntimeClass | Hypervisor | Config File |
|--------------|------------|-------------|
| `kata` | Default (QEMU) | `configuration.toml` |
| `kata-qemu` | QEMU | `configuration-qemu.toml` |
| `kata-clh` | Cloud Hypervisor | `configuration-clh.toml` |
| `kata-fc` | Firecracker | `configuration-fc.toml` |

## Cleanup

```bash
# Delete test pod
multipass exec microk8s-crio -- sudo microk8s kubectl delete pod test-kata

# Delete VM entirely
multipass delete microk8s-crio
multipass purge
```

## Troubleshooting

### "file not found" errors (e.g., "/bin/bash was not found")

This is the most common issue. The container rootfs is not being shared properly with the Kata VM.

**Solution:** Ensure `/etc/crio/crio.conf.d/00-storage.conf` contains:
```toml
[crio]
storage_option = [
  "overlay.skip_mount_home=true",
]
```

**Important:** If this setting is added after MicroK8s was already running, you must **reboot the VM** (not just restart services) for it to take effect.

### Pod stuck in ContainerCreating

Check CRI-O logs:
```bash
multipass exec microk8s-crio -- sudo journalctl -u crio -f
```

### Check nested virtualization

```bash
multipass exec microk8s-crio -- ls -la /dev/kvm
```

If `/dev/kvm` doesn't exist, nested virtualization is not enabled on the host.

### Verify CRI-O is using the correct config

```bash
multipass exec microk8s-crio -- sudo crio config 2>/dev/null | grep -A2 storage_option
```

### Check Kata processes are running

```bash
multipass exec microk8s-crio -- ps aux | grep -E "(qemu|kata|virtiofsd)"
```

## Key Differences from containerd Setup

| Aspect | containerd | CRI-O |
|--------|------------|-------|
| Config location | `/var/snap/microk8s/current/args/containerd-template.toml` | `/etc/crio/crio.conf.d/` |
| Runtime type | `io.containerd.kata.v2` | `vm` |
| Storage config | Not needed | **Required:** `overlay.skip_mount_home=true` |
| Restart behavior | Service restart sufficient | **Full reboot required** for storage changes |

## Key Paths

| Component | Path |
|-----------|------|
| CRI-O config | `/etc/crio/crio.conf.d/` |
| CRI-O socket | `/var/run/crio/crio.sock` |
| Kata binaries | `/opt/kata/bin/` |
| Kata shim | `/opt/kata/bin/containerd-shim-kata-v2` |
| Kata configs | `/opt/kata/share/defaults/kata-containers/` |
| MicroK8s kubelet args | `/var/snap/microk8s/current/args/kubelet` |

## References

- [Kata Containers CRI-O issue #9878](https://github.com/kata-containers/kata-containers/issues/9878) - Root cause of "file not found" errors
- [CRI-O issue #8322](https://github.com/cri-o/cri-o/issues/8322) - Storage option fix
- [CRI-O Installation](https://cri-o.io/)
- [Kata Containers releases](https://github.com/kata-containers/kata-containers/releases)
- [MicroK8s documentation](https://microk8s.io/docs)
