# Kata Containers Development Notes

## Quick Reference — Multipass k3s (primary test environment)

**VM:** `kata-dev` (Multipass, 4 CPU, 8GB RAM, 50GB disk, Ubuntu 24.04)
**Runtime:** k3s + CRI-O + kata-deploy (qemu-coco-dev, runtime-rs)
**Kubeconfig:** `/tmp/kata-dev-kubeconfig.yaml`

### Scripts

```bash
# Provision VM (idempotent, includes k3s + CRI-O + kata-deploy + MicroCeph + ceph-csi)
./scripts/kata-dev-up.sh            # full setup
./scripts/kata-dev-up.sh --no-ceph  # skip MicroCeph + ceph-csi

# Run BATS integration tests
./scripts/kata-dev-test.sh                        # all 39 applicable tests
./scripts/kata-dev-test.sh k8s-env.bats           # single test
./scripts/kata-dev-test.sh k8s-env.bats k8s-exec.bats  # multiple tests
./scripts/kata-dev-test.sh --list                  # list test names
./scripts/kata-dev-test.sh --setup-only            # prepare workloads_work dir only

# Stop or delete VM
./scripts/kata-dev-down.sh           # stop (preserves state)
./scripts/kata-dev-down.sh --delete  # destroy entirely
```

### Running tests manually

If you need to run tests outside the runner script, use these env vars:

```bash
export KUBECONFIG=/tmp/kata-dev-kubeconfig.yaml
export KATA_HYPERVISOR=qemu-coco-dev
export KUBERNETES=k3s
export AUTO_GENERATE_POLICY=no

cd tests/integration/kubernetes
bash setup.sh  # creates runtimeclass_workloads_work/
bats k8s-env.bats
```

**Important:** `KATA_HYPERVISOR=qemu-coco-dev` must match the actual runtime config.
Using `qemu` causes tests that require CPU hotplug or seccomp to fail instead of skip.

### Test exclusions

Tests excluded from the suite (not applicable to single-node k3s + qemu-coco-dev):

| Category | Tests | Reason |
|----------|-------|--------|
| Confidential | `k8s-confidential*.bats`, `k8s-sealed-secret.bats`, `k8s-measured-rootfs.bats` | No TEE hardware |
| NVIDIA | `k8s-nvidia-*.bats` | No GPU |
| Guest pull | `k8s-guest-pull-image*.bats`, `k8s-empty-image.bats` | Needs nydus/guest-pull config |
| Policy | `k8s-policy-*.bats` | Needs genpolicy + policy agent |
| Special setup | `k8s-openvpn.bats`, `k8s-footloose.bats` | Needs extra infra |
| Host config | `k8s-sandbox-cgroup.bats`, `k8s-sandbox-vcpus-allocation.bats` | Needs specific host cgroup/CPU config |

### Known skips and failures

| Test | Status | Reason |
|------|--------|--------|
| `k8s-cpu-ns` | skip | `static_sandbox_resource_mgmt=true` disables CPU hotplug |
| `k8s-seccomp` | skip | Intermittent on qemu-coco-dev |
| `k8s-custom-dns` | skip | Known issue [#9663](https://github.com/kata-containers/kata-containers/issues/9663) |
| `k8s-oom` | fail | Pre-existing, unrelated to our changes |
| `k8s-port-forward` | skip | Known issue [#1834](https://github.com/kata-containers/runtime/issues/1834) |

### VM components

| Component | Version | Notes |
|-----------|---------|-------|
| k3s | v1.34 | `--container-runtime-endpoint unix:///var/run/crio/crio.sock` |
| CRI-O | v1.33 | apt repo `isv:/cri-o:/stable:/v1.33` |
| kata-deploy | 3.28.0 | Helm chart, qemu-coco-dev shim |
| yq | v4.44.5 | mikefarah/yq, installed on **host** and VM |
| MicroCeph | snap | 3 loop OSD disks (2GB each) |
| ceph-csi-rbd | 3.16.2 | Helm chart, `ceph-rbd` StorageClass |

### Key paths (inside VM)

| Component | Path |
|-----------|------|
| Kata runtime-rs shim | `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` |
| qemu-coco-dev config | `/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/configuration-qemu-coco-dev.toml` |
| runtime-rs config | `/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-coco-dev-runtime-rs.toml` |
| CRI-O kata config | `/etc/crio/crio.conf.d/99-kata-deploy` |
| CNI config | `/etc/cni/net.d/10-flannel.conflist` (symlink to k3s) |

### Architecture

```
Host PC
└─ Multipass VM "kata-dev" (KVM, 8GB RAM, 4 CPU)
   ├─ /dev/kvm (nested virtualization)
   ├─ k3s (control plane + worker)
   ├─ CRI-O (container runtime)
   ├─ kata-deploy DaemonSet
   │   └─ qemu-coco-dev runtime (runtime-rs)
   ├─ MicroCeph (3 OSD, ceph-rbd StorageClass)
   └─ Kubernetes
       └─ Pod with runtimeClassName: kata
           └─ Kata Guest VM (QEMU)
               └─ Container
```

---

<details>
<summary>Legacy: Testing Kata + Dragonball with Minikube</summary>

**kubectl context:** `minikube`

**Quick setup (after minikube exists):**
```bash
# Remount persistent storage (lost on VM restart)
minikube ssh "sudo mkdir -p /mnt/vda1/opt/kata && sudo mkdir -p /opt/kata && sudo mount --bind /mnt/vda1/opt/kata /opt/kata"

# Install Kata with Dragonball
helm install kata-deploy ./tools/packaging/kata-deploy/helm-chart/kata-deploy \
  --namespace kube-system \
  --set shims.disableAll=true \
  --set shims.dragonball.enabled=true \
  --set defaultShim.amd64=dragonball \
  --set runtimeClasses.createDefault=false \
  --set debug=true

# Wait for installation
kubectl --context minikube wait --for=condition=ready pod -l app=kata-deploy -n kube-system --timeout=600s
```

### Prerequisites

**Host requirements:**
- Linux with KVM support
- Nested virtualization enabled
- At least 16GB RAM (8GB for VM + host overhead)
- User in `kvm` and `libvirt` groups

**Verify nested virtualization:**
```bash
cat /sys/module/kvm_intel/parameters/nested   # Intel
cat /sys/module/kvm_amd/parameters/nested     # AMD
# Should return "Y" or "1"
```

### Create Minikube Cluster

```bash
minikube start \
  --driver=kvm2 \
  --container-runtime=containerd \
  --memory=8192 \
  --cpus=2 \
  --disk-size=30g
```

### Key Paths

| Component | Path |
|-----------|------|
| Kata runtime-rs shim | `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` |
| Dragonball config | `/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-dragonball.toml` |
| Kata guest kernel | `/opt/kata/share/kata-containers/vmlinux-dragonball-experimental.container` |
| Kata guest image | `/opt/kata/share/kata-containers/kata-containers.img` |

</details>
