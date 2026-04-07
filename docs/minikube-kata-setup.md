# Minikube with Kata Containers Setup Guide

This guide describes how to set up Kata Containers with Dragonball hypervisor on minikube using containerd.

## Prerequisites

**Host requirements:**
- Linux with KVM support
- Nested virtualization enabled (for running Kata VMs inside minikube VM)
- At least 16GB RAM (8GB for minikube VM + host overhead)
- minikube installed with KVM2 driver
- Helm 3 installed

**Verify nested virtualization:**
```bash
# Check if enabled (Intel)
cat /sys/module/kvm_intel/parameters/nested
# Check if enabled (AMD)
cat /sys/module/kvm_amd/parameters/nested
# Should return "Y" or "1"

# Enable if needed (Intel)
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1

# Make permanent
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
```

## Step 1: Create Minikube Cluster

```bash
# Delete any existing cluster
minikube delete 2>/dev/null

# Create cluster with containerd
minikube start \
  --driver=kvm2 \
  --container-runtime=containerd \
  --memory=8192 \
  --cpus=2 \
  --disk-size=30g
```

**Important:** 8GB RAM is the minimum. Lower values may cause issues during Kata installation.

## Step 2: Verify Nested Virtualization in VM

```bash
minikube ssh "ls -la /dev/kvm"
# Should show: crw-rw-rw- 1 root kvm 10, 232 ... /dev/kvm
```

## Step 3: Prepare Persistent Storage for Kata

Minikube uses tmpfs for parts of the root filesystem. Kata artifacts (~2.5GB) need persistent storage:

```bash
minikube ssh "sudo mkdir -p /mnt/vda1/opt/kata && sudo mkdir -p /opt/kata && sudo mount --bind /mnt/vda1/opt/kata /opt/kata"
```

**Note:** This bind mount is lost on VM restart. Re-run after `minikube start`.

## Step 4: Build Helm Dependencies

Clone the kata-containers repository if you haven't already:

```bash
git clone https://github.com/kata-containers/kata-containers.git
cd kata-containers
```

Build Helm chart dependencies:

```bash
helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts
cd tools/packaging/kata-deploy/helm-chart/kata-deploy
helm dependency build
cd -
```

## Step 5: Install Kata with Dragonball

```bash
helm install kata-deploy ./tools/packaging/kata-deploy/helm-chart/kata-deploy \
  --namespace kube-system \
  --set shims.disableAll=true \
  --set shims.dragonball.enabled=true \
  --set defaultShim.amd64=dragonball \
  --set runtimeClasses.createDefault=false \
  --set debug=true
```

**Note:** We use `runtimeClasses.createDefault=false` because the chart already creates `kata-dragonball` RuntimeClass from the enabled shim.

## Step 6: Wait for Installation

The kata-deploy image is ~1.8GB. Installation takes several minutes:

```bash
kubectl wait --for=condition=ready pod -l name=kata-deploy -n kube-system --timeout=600s
```

**Monitor progress:**
```bash
kubectl logs -f -n kube-system -l name=kata-deploy
```

**Expected final log:**
```
Kata Containers installation completed successfully
Install completed, daemonset mode: sleeping forever
```

## Step 7: Verify Installation

```bash
# Check node is labeled
kubectl get nodes -L katacontainers.io/kata-runtime
# Should show: KATA-RUNTIME = true

# Check RuntimeClass
kubectl get runtimeclass
# Should show: kata-dragonball

# Check Kata binaries
minikube ssh "ls /opt/kata/runtime-rs/bin/"
# Should show: containerd-shim-kata-v2
```

## Step 8: Test with a Pod

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-kata-dragonball
spec:
  runtimeClassName: kata-dragonball
  containers:
  - name: nginx
    image: nginx:alpine
EOF
```

Wait for pod to be running:

```bash
kubectl wait --for=condition=ready pod/nginx-kata-dragonball --timeout=120s
```

**Verify it's running in a Kata VM:**
```bash
# Pod kernel (Kata guest) - should be ~6.12.x
kubectl exec nginx-kata-dragonball -- uname -r

# Host kernel (minikube) - should be ~5.10.x (different from pod)
minikube ssh "uname -r"

# Kata shim process
minikube ssh "ps aux | grep containerd-shim-kata"
# Should show: /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
```

## Cleanup

```bash
kubectl delete pod nginx-kata-dragonball
helm uninstall kata-deploy -n kube-system --no-hooks
minikube delete
```

## Troubleshooting

### Helm install fails with "runtimeclass already exists"

Minikube or a previous install may have created the RuntimeClass. Uninstall cleanly:

```bash
helm uninstall kata-deploy -n kube-system --no-hooks
kubectl delete runtimeclass kata-dragonball
```

### Helm install fails with "cannot re-use a name"

A failed Helm release may be stuck. Clean up:

```bash
helm uninstall kata-deploy -n kube-system --no-hooks
kubectl delete secret -n kube-system -l owner=helm,name=kata-deploy
```

### kata-deploy pod keeps restarting

Check logs for errors:

```bash
kubectl logs -n kube-system -l name=kata-deploy --previous
```

Common issues:
- Disk space: Ensure persistent storage is set up (Step 3)
- Memory: Ensure minikube has at least 8GB RAM

### Pod stuck in ContainerCreating

Check events:

```bash
kubectl describe pod nginx-kata-dragonball
```

If you see "FailedCreatePodSandBox" errors, the node may not have the kata-runtime label yet. Wait for kata-deploy to complete.

### API server timeouts during installation

The kata-deploy image pull (~1.8GB) and artifact copy (~2.5GB) cause high I/O. This is normal. Wait for installation to complete.

## Architecture

```
Host PC
└─ Minikube VM (KVM, 8GB RAM)
   ├─ /dev/kvm (nested virtualization)
   ├─ containerd
   │   └─ kata-dragonball runtime
   └─ Kubernetes
       └─ Pod with runtimeClassName: kata-dragonball
           └─ Kata Guest VM (Dragonball hypervisor)
               └─ Container
```

## Key Paths

| Component | Path |
|-----------|------|
| Kata runtime-rs shim | `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` |
| Dragonball config | `/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-dragonball.toml` |
| Kata guest kernel | `/opt/kata/share/kata-containers/vmlinux-dragonball-experimental.container` |
| Kata guest image | `/opt/kata/share/kata-containers/kata-containers.img` |

## Tested Versions

| Component | Version |
|-----------|---------|
| minikube | v1.36.0 |
| Kubernetes | v1.33.1 |
| containerd | 1.7.23 |
| Kata Containers | 3.26.0 |
| Kata guest kernel | 6.12.47 |

## Known Issues

### Kata + CRI-O compatibility

Kata Containers has a known issue with CRI-O where the container rootfs is not properly shared with the Kata guest VM, resulting in "file not found" errors. Use containerd instead of CRI-O for Kata workloads.

Related issues:
- https://github.com/kata-containers/kata-containers/issues/10004
- https://github.com/kata-containers/kata-containers/issues/11311

## References

- [Kata Containers Documentation](https://katacontainers.io/docs/)
- [Kata Deploy Helm Chart](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy/helm-chart)
- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)
