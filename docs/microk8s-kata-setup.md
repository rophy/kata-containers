# MicroK8s with Kata Containers Setup Guide

This guide covers manual installation of Kata Containers on MicroK8s using Multipass VMs.

## Why Manual Installation?

The `kata-deploy` DaemonSet assumes standard Kubernetes installations and has issues with non-standard distributions:
- MicroK8s uses custom containerd paths (`/var/snap/microk8s/...`)
- kata-deploy doesn't configure containerd correctly for MicroK8s
- The 2.5GB artifact copy can saturate disk I/O, causing API server timeouts

Manual installation provides full control and avoids these issues.

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
multipass launch --name microk8s-vm --cpus 4 --memory 8G --disk 30G
```

**Note:** 8GB RAM minimum recommended. 4GB may cause OOM issues.

## Step 2: Install MicroK8s

```bash
multipass exec microk8s-vm -- sudo snap install microk8s --classic
multipass exec microk8s-vm -- sudo usermod -aG microk8s ubuntu
multipass exec microk8s-vm -- sudo microk8s status --wait-ready
```

## Step 3: Copy and Extract Kata Release

```bash
# Copy from host to VM
multipass transfer kata-static-3.26.0-amd64.tar.zst microk8s-vm:/home/ubuntu/

# Install zstd and extract
multipass exec microk8s-vm -- sudo apt-get update
multipass exec microk8s-vm -- sudo apt-get install -y zstd
multipass exec microk8s-vm -- sudo tar -C / -xvf /home/ubuntu/kata-static-3.26.0-amd64.tar.zst
```

## Step 4: Create Containerd Shim Symlink

```bash
multipass exec microk8s-vm -- sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
```

## Step 5: Configure Containerd

Create the containerd configuration with Kata runtimes:

```bash
multipass exec microk8s-vm -- sudo tee /var/snap/microk8s/current/args/containerd-template.toml << 'EOF'
# Use config version 2 to enable new configuration fields.
version = 2
oom_score = 0

[grpc]
  uid = 0
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  address = ""
  uid = 0
  gid = 0

[metrics]
  address = "127.0.0.1:1338"
  grpc_histogram = false

[cgroup]
  path = ""

[plugins."io.containerd.grpc.v1.cri"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  enable_selinux = false
  sandbox_image = "registry.k8s.io/pause:3.10"
  stats_collect_period = 10
  enable_tls_streaming = false
  max_container_log_line_size = 16384

  [plugins."io.containerd.grpc.v1.cri".containerd]
    snapshotter = "${SNAPSHOTTER}"
    no_pivot = false
    default_runtime_name = "${RUNTIME}"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "${RUNTIME_TYPE}"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime]
      runtime_type = "${RUNTIME_TYPE}"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime.options]
        BinaryName = "nvidia-container-runtime"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
      privileged_without_host_devices = true
      pod_annotations = ["io.katacontainers.*"]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
        ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration.toml"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu]
      runtime_type = "io.containerd.kata.v2"
      privileged_without_host_devices = true
      pod_annotations = ["io.katacontainers.*"]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu.options]
        ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-qemu.toml"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
      runtime_type = "io.containerd.kata.v2"
      privileged_without_host_devices = true
      pod_annotations = ["io.katacontainers.*"]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
        ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-clh.toml"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc]
      runtime_type = "io.containerd.kata.v2"
      privileged_without_host_devices = true
      pod_annotations = ["io.katacontainers.*"]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc.options]
        ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"

  [plugins."io.containerd.grpc.v1.cri".cni]
    bin_dir = "${SNAP_DATA}/opt/cni/bin"
    conf_dir = "${SNAP_DATA}/args/cni-network"

  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "${SNAP_DATA}/args/certs.d"
EOF
```

## Step 6: Restart MicroK8s

```bash
multipass exec microk8s-vm -- sudo microk8s stop
multipass exec microk8s-vm -- sudo microk8s start
multipass exec microk8s-vm -- sudo microk8s status --wait-ready
```

## Step 7: Create RuntimeClasses

```bash
multipass exec microk8s-vm -- sudo microk8s kubectl apply -f - << 'EOF'
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

## Step 8: Verify Installation

```bash
# Check RuntimeClasses
multipass exec microk8s-vm -- sudo microk8s kubectl get runtimeclass

# Check Kata binaries
multipass exec microk8s-vm -- ls /opt/kata/bin/
```

Expected output:
```
NAME        HANDLER      AGE
kata        kata         1m
kata-clh    kata-clh     1m
kata-fc     kata-fc      1m
kata-qemu   kata-qemu    1m
```

## Step 9: Test with a Pod

```bash
multipass exec microk8s-vm -- sudo microk8s kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nginx-kata
spec:
  runtimeClassName: kata
  containers:
  - name: nginx
    image: nginx:alpine
EOF

# Wait for pod
multipass exec microk8s-vm -- sudo microk8s kubectl wait --for=condition=ready pod/nginx-kata --timeout=120s

# Verify different kernel (Kata guest vs host)
echo "Pod kernel:"
multipass exec microk8s-vm -- sudo microk8s kubectl exec nginx-kata -- uname -r

echo "Host kernel:"
multipass exec microk8s-vm -- uname -r
```

The pod kernel (e.g., `6.12.x`) should differ from the host kernel (e.g., `6.8.x`), confirming the pod runs in a Kata VM.

## Available Runtimes

| RuntimeClass | Hypervisor | Config File |
|--------------|------------|-------------|
| `kata` | Default (QEMU) | `configuration.toml` |
| `kata-qemu` | QEMU | `configuration-qemu.toml` |
| `kata-clh` | Cloud Hypervisor | `configuration-clh.toml` |
| `kata-fc` | Firecracker | `configuration-fc.toml` |

## Performance Benchmarks

Benchmarks run on MicroK8s with manual Kata installation (Multipass VM, 4 CPUs, 8GB RAM):

### CPU Performance (sysbench)

| Runtime | Events/s (avg) | Overhead |
|---------|----------------|----------|
| runc | ~929 | baseline |
| kata | ~914 | **~2%** |

### I/O Performance (fio, 4k random, direct I/O)

| Metric | runc | kata | Notes |
|--------|------|------|-------|
| Read IOPS | 64.2k | 44.0k | ~1.5x slower |
| Write IOPS | 32.4k | 41.4k | Kata faster (VM caching) |

**Note:** I/O results vary due to virtio-fs overhead and VM caching behavior.

## Cleanup

```bash
# Delete test pod
multipass exec microk8s-vm -- sudo microk8s kubectl delete pod nginx-kata

# Delete VM entirely
multipass delete microk8s-vm
multipass purge
```

## Troubleshooting

### Pod stuck in ContainerCreating

Check containerd logs:
```bash
multipass exec microk8s-vm -- sudo journalctl -u snap.microk8s.daemon-containerd -f
```

### Kata shim not found

Verify symlink exists:
```bash
multipass exec microk8s-vm -- ls -la /usr/local/bin/containerd-shim-kata-v2
```

### Check nested virtualization

```bash
multipass exec microk8s-vm -- ls -la /dev/kvm
```

If `/dev/kvm` doesn't exist, nested virtualization is not enabled on the host.

### TOML parse errors on MicroK8s restart

If containerd fails to start after editing the template, check for TOML syntax errors:
```bash
multipass exec microk8s-vm -- sudo cat /var/snap/microk8s/current/args/containerd-template.toml
```

Common issues:
- Duplicate table entries (e.g., two `[plugins..."runtimes.kata"]` sections)
- Missing closing brackets

## Key Paths

| Component | Path |
|-----------|------|
| Kata binaries | `/opt/kata/bin/` |
| Kata shim | `/opt/kata/bin/containerd-shim-kata-v2` |
| Kata configs | `/opt/kata/share/defaults/kata-containers/` |
| containerd template | `/var/snap/microk8s/current/args/containerd-template.toml` |
| Shim symlink | `/usr/local/bin/containerd-shim-kata-v2` |

## References

- [Kata Containers containerd installation guide](https://github.com/kata-containers/kata-containers/blob/main/docs/install/container-manager/containerd/containerd-install.md)
- [MicroK8s documentation](https://microk8s.io/docs)
- [Kata Containers releases](https://github.com/kata-containers/kata-containers/releases)
