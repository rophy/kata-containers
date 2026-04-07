# Kata Containers Development Notes

## Quick Reference

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

---

## Testing Kata + Dragonball with Minikube (Nested VM)

This guide describes how to run Kubernetes with Kata Containers and Dragonball hypervisor in a nested VM environment using Minikube.

### Prerequisites

**Host requirements:**
- Linux with KVM support
- Nested virtualization enabled
- At least 16GB RAM (8GB for VM + host overhead)
- User in `kvm` and `libvirt` groups

**Verify nested virtualization:**
```bash
# Check if enabled
cat /sys/module/kvm_intel/parameters/nested   # Intel
cat /sys/module/kvm_amd/parameters/nested     # AMD
# Should return "Y" or "1"

# Enable if needed (Intel)
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1

# Make permanent
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
```

**Add user to groups:**
```bash
sudo usermod -aG kvm,libvirt $USER
# Log out and back in for changes to take effect
```

### Step 1: Create Minikube Cluster

```bash
minikube delete 2>/dev/null  # Clean up any existing cluster

minikube start \
  --driver=kvm2 \
  --container-runtime=containerd \
  --memory=8192 \
  --cpus=2 \
  --disk-size=30g
```

**Important:** 8GB RAM is the minimum. 4GB will cause OOM kills during Kata installation.

### Step 2: Verify Nested Virtualization in VM

```bash
minikube ssh "ls -la /dev/kvm"
# Should show: crw-rw-rw- 1 root kvm 10, 232 ... /dev/kvm
```

### Step 3: Prepare Persistent Storage for Kata

Minikube uses tmpfs for root filesystem which is limited. Kata artifacts (~2.5GB) need persistent storage:

```bash
minikube ssh "sudo mkdir -p /mnt/vda1/opt/kata && sudo mkdir -p /opt/kata && sudo mount --bind /mnt/vda1/opt/kata /opt/kata"
```

**Note:** This bind mount is lost on VM restart. Re-run after `minikube start`.

### Step 4: Build Helm Dependencies

```bash
cd tools/packaging/kata-deploy/helm-chart/kata-deploy
helm dependency build
```

### Step 5: Install Kata with Dragonball

```bash
helm install kata-deploy ./tools/packaging/kata-deploy/helm-chart/kata-deploy \
  --namespace kube-system \
  --set shims.disableAll=true \
  --set shims.dragonball.enabled=true \
  --set defaultShim.amd64=dragonball \
  --set runtimeClasses.createDefault=true \
  --set runtimeClasses.defaultName=kata-dragonball \
  --set debug=true
```

If you get "runtimeclass already exists" error, use `helm upgrade` instead:
```bash
helm upgrade kata-deploy ./tools/packaging/kata-deploy/helm-chart/kata-deploy \
  --namespace kube-system \
  --set shims.disableAll=true \
  --set shims.dragonball.enabled=true \
  --set defaultShim.amd64=dragonball \
  --set runtimeClasses.createDefault=true \
  --set runtimeClasses.defaultName=kata-dragonball \
  --set debug=true
```

### Step 6: Wait for Installation

The kata-deploy image is ~1.8GB. Installation takes several minutes:

```bash
kubectl wait --for=condition=ready pod -l app=kata-deploy -n kube-system --timeout=600s
```

**Monitor progress:**
```bash
kubectl logs -f -n kube-system -l app=kata-deploy
```

**Expected final log:**
```
Kata Containers installation completed successfully
Install completed, daemonset mode: sleeping forever
```

### Step 7: Verify Installation

```bash
# Check RuntimeClass
kubectl get runtimeclass
# Should show: kata-dragonball

# Check Kata binaries
minikube ssh "ls /opt/kata/runtime-rs/bin/"
# Should show: containerd-shim-kata-v2
```

### Step 8: Test with a Pod

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

**Verify it's running in a Kata VM:**
```bash
# Pod kernel (Kata guest)
kubectl exec nginx-kata-dragonball -- uname -r
# Should show something like: 6.12.47

# Host kernel
minikube ssh "uname -r"
# Should show something like: 5.10.207 (different from pod)

# Kata shim process
minikube ssh "ps aux | grep containerd-shim-kata"
# Should show: /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
```

### Cleanup

```bash
kubectl delete pod nginx-kata-dragonball
helm uninstall kata-deploy -n kube-system
minikube delete
```

### Troubleshooting

**API server stops / etcd timeouts:**
- Usually caused by disk I/O saturation during Kata file copy
- Wait for installation to complete, then run `minikube start` to recover

**"No space left on device" error:**
- tmpfs is full; ensure bind mount to persistent storage (Step 3)

**OOM kills:**
- Increase VM memory to 8GB or more

**Check disk I/O:**
```bash
minikube ssh "iostat -x 1 3"
# High %iowait indicates disk bottleneck
```

**Check memory:**
```bash
minikube ssh "free -h"
```

**Check for OOM kills:**
```bash
minikube ssh "sudo dmesg | grep -i oom"
```

### Architecture

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

### Key Paths

| Component | Path |
|-----------|------|
| Kata runtime-rs shim | `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` |
| Dragonball config | `/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-dragonball.toml` |
| Kata guest kernel | `/opt/kata/share/kata-containers/vmlinux-dragonball-experimental.container` |
| Kata guest image | `/opt/kata/share/kata-containers/kata-containers.img` |
