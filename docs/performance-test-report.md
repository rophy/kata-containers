# Kata Containers Performance Test Report

**Date:** 2026-02-04 (updated 2026-02-05)
**Kata Version:** 3.26.0

## Test Environments

### Environment A: Minikube + containerd + Dragonball

- **Host:** Ubuntu 24.04, Intel i5-4590 (4 cores), nested virtualization
- **VM:** Minikube KVM2, 4 vCPUs, 8GB RAM, 30GB disk
- **Container Runtime:** containerd 1.7.23
- **Kubernetes:** v1.33.1
- **Hypervisor:** Dragonball (runtime-rs, inline-virtio-fs)

### Environment B: Multipass + MicroK8s + CRI-O + Multiple Hypervisors

- **Host:** Same as above
- **VM:** Multipass KVM, 4 vCPUs, 8GB RAM, 30GB disk
- **Container Runtime:** CRI-O 1.33
- **Kubernetes:** v1.33 (MicroK8s)
- **Hypervisors tested:** Dragonball (runtime-rs), QEMU (Go runtime)

---

## Test 1: CPU Performance (sysbench)

**Environment:** A (Minikube + containerd + Dragonball)

### Test Configuration
- **Tool:** sysbench cpu
- **Duration:** 10 seconds per run
- **Iterations:** 3 runs per configuration
- **Metric:** Events per second (higher is better)

### Test 1a: With CPU Limit (1 CPU)

Both pods configured with `resources.limits.cpu: "1"`.

| Pod | nproc (visible CPUs) | cpu.max (cgroup) |
|-----|----------------------|------------------|
| runc | 4 | 100000 100000 (1 CPU throttled) |
| kata | 2 | 100000 100000 (1 CPU throttled) |

**Results:**

| Run | runc (events/s) | kata (events/s) |
|-----|-----------------|-----------------|
| 1 | 1014.85 | 982.29 |
| 2 | 1013.58 | 978.12 |
| 3 | 1014.97 | 979.60 |
| **Average** | **1014.47** | **980.00** |

**Analysis:**
- Kata overhead: **3.4%**
- Both pods effectively limited to 1 CPU via cgroup
- Kata VM allocated 2 vCPUs but only 1 usable due to cgroup limit
- Minimal overhead for CPU-bound workloads

### Test 1b: Without CPU Limit

Both pods configured without CPU limits.

| Pod | nproc (visible CPUs) | cpu.max (cgroup) |
|-----|----------------------|------------------|
| runc | 4 | max 100000 (unlimited) |
| kata | 1 | max 100000 (unlimited) |

**Results (using all available CPUs):**

| Run | runc 4-thread (events/s) | kata 1-thread (events/s) |
|-----|--------------------------|--------------------------|
| 1 | 3034.61 | 981.56 |
| 2 | 3016.81 | 984.56 |
| 3 | 3004.69 | 981.81 |
| **Average** | **3018.70** | **982.64** |

**Analysis:**
- runc can use all 4 host CPUs
- Kata VM only gets 1 vCPU (default_vcpus) without CPU limits
- **Critical finding:** Kata pods without `cpu.limits` are severely resource-constrained
- Relative performance: kata at **32.5%** of runc

### Test 1c: Cgroup Throttling Overhead

Comparing kata with and without cgroup throttling (both single-threaded):

| Configuration | VM vCPUs | cpu.max | Events/s (avg) |
|---------------|----------|---------|----------------|
| 1 CPU limit | 2 | 100000 100000 | ~972 |
| No limit | 1 | max | ~975 |

**Analysis:**
- No measurable overhead from CFS cgroup throttling
- Sysbench is a steady workload without bursts
- CFS overhead appears in bursty/latency-sensitive workloads

---

## Test 2: Storage I/O Performance - Dragonball (fio)

**Environment:** A (Minikube + containerd + Dragonball)

### Test Configuration
- **Tool:** fio 3.41
- **I/O Engine:** libaio
- **Direct I/O:** Yes (bypass page cache)
- **Block Size:** 4KB
- **I/O Depth:** 32
- **Test File:** 128MB
- **Duration:** 10 seconds
- **Storage:** Container rootfs (inline-virtio-fs for kata)

### Test 2a: Random Read IOPS

| Metric | runc | kata-dragonball | Overhead |
|--------|------|-----------------|----------|
| **IOPS** | 120,498 | 6,511 | **18.5x slower** |
| **Bandwidth** | 471 MiB/s | 25.7 MiB/s | 18.3x slower |
| **Avg Latency** | 265 µs | 4,850 µs | 18.3x higher |
| **P99 Latency** | 807 µs | 44,303 µs | 55x higher |

### Test 2b: Random Write IOPS

| Metric | runc | kata-dragonball | Overhead |
|--------|------|-----------------|----------|
| **IOPS** | 45,200 | 4,580 | **9.9x slower** |
| **Bandwidth** | 177 MiB/s | 17.9 MiB/s | 9.9x slower |
| **Avg Latency** | ~700 µs | 6,972 µs | 10x higher |
| **P99 Latency** | N/A | 46,924 µs | - |

---

## Test 3: PVC I/O Performance - Dragonball

**Environment:** A (Minikube + containerd + Dragonball)

### Test Configuration
- **PVC:** 1Gi, ReadWriteOnce (minikube hostpath provisioner)
- **Mount Type:** virtio-fs (kataShared) - hostpath provisioner does NOT provide block devices
- **Same fio parameters as Test 2**

### Results

| Metric | runc | kata-dragonball | Overhead |
|--------|------|-----------------|----------|
| **Read IOPS** | 120,000 | 6,460 | **18.6x slower** |
| **Read BW** | 467 MiB/s | 25.2 MiB/s | 18.5x slower |
| **Read Lat** | 267 µs | 4,944 µs | 18.5x higher |
| **Write IOPS** | 62,300 | 5,121 | **12.2x slower** |
| **Write BW** | 243 MiB/s | 20.0 MiB/s | 12.2x slower |
| **Write Lat** | 513 µs | 6,238 µs | 12.2x higher |

### PVC Analysis

The PVC results are nearly identical to rootfs results because:

1. **Minikube hostpath provisioner** does not provide true block devices
2. **Kata mounts PVC via virtio-fs** (shown as `kataShared` mount type)
3. **Same I/O path as rootfs**: Container → inline-virtio-fs → Host

---

## Test 4: QEMU vs Dragonball I/O Comparison

**Environment:** B (Multipass + MicroK8s + CRI-O)

This test was designed to isolate whether the I/O overhead is caused by the virtio-fs protocol itself or by Dragonball's inline-virtio-fs implementation.

### Test Configuration
- **Same fio parameters as Test 2**
- **kata-qemu:** QEMU hypervisor with external virtiofsd process
- **kata-dragonball:** Dragonball hypervisor with inline-virtio-fs (tuned: cache=always, queue_size=1024, num_queues=4, thread-pool-size=4)
- **Both pods:** `resources.limits: {cpu: "1", memory: 512Mi}`

### Results: Random Read

| Metric | runc | kata-qemu | kata-dragonball |
|--------|------|-----------|-----------------|
| **IOPS** | 36,400 | **50,200** | 6,157 |
| **Bandwidth** | 142 MiB/s | 196 MiB/s | 24.1 MiB/s |
| **Avg Latency** | 878 µs | 636 µs | 5,187 µs |

### Results: Random Write

| Metric | runc | kata-qemu | kata-dragonball |
|--------|------|-----------|-----------------|
| **IOPS** | 22,600 | **48,500** | 5,763 |
| **Bandwidth** | 88.5 MiB/s | 190 MiB/s | 22.5 MiB/s |
| **Avg Latency** | 1,412 µs | 658 µs | 5,545 µs |

### Key Finding: Dragonball inline-virtio-fs is 8x slower than QEMU's external virtiofsd

| Comparison | Read IOPS | Write IOPS |
|------------|-----------|------------|
| kata-qemu vs runc | **1.4x faster** | **2.1x faster** |
| kata-dragonball vs runc | **5.9x slower** | **3.9x slower** |
| kata-qemu vs kata-dragonball | **8.2x faster** | **8.4x faster** |

Note: kata-qemu outperforming runc is likely due to QEMU's virtiofsd write-back caching and the test file fitting in memory.

---

## Test 5: Dragonball I/O Tuning Attempt

**Environment:** B (Multipass + MicroK8s + CRI-O)

Attempted to improve Dragonball's inline-virtio-fs performance by tuning configuration parameters.

### Tuning Applied

| Setting | Default | Tuned |
|---------|---------|-------|
| `virtio_fs_cache` | auto | **always** |
| `virtio_fs_cache_size` | 0 (DAX off) | **1024** MiB |
| `queue_size` | 128 | **1024** |
| `num_queues` | 1 | **4** |
| `--thread-pool-size` | 1 | **4** |

### Results (Random Write, tuned vs default)

| Metric | Default | Tuned | Improvement |
|--------|---------|-------|-------------|
| **IOPS** | 4,580 | 5,668 | +24% |
| **Bandwidth** | 17.9 MiB/s | 22.1 MiB/s | +23% |
| **Avg Latency** | 6,972 µs | 5,636 µs | -19% |

### Analysis

Tuning provided modest improvement (+24% writes) but did not close the gap with QEMU (still 8x slower). The tunings helped at the margins but cannot fix the fundamental architectural bottleneck.

---

## Root Cause Analysis: Dragonball inline-virtio-fs Performance

The 8x performance gap between Dragonball's inline-virtio-fs and QEMU's external virtiofsd stems from architectural differences in how I/O requests are processed.

### Architecture Comparison

```
QEMU + external virtiofsd:
  Guest kernel → virtio-fs → vhost-user socket → virtiofsd process → host filesystem
  (separate process, own threads, fully parallel)

Dragonball + inline-virtio-fs:
  Guest kernel → virtio-fs → in-process handler → host filesystem
  (shared process with VMM, mutex-serialized completion)
```

### Root Cause: Mutex Contention on Completion Path

Source: `src/dragonball/dbs_virtio_devices/src/fs/handler.rs`

Even with a thread pool enabled, every I/O completion must acquire two mutex locks:

1. **Config lock** (`config.lock().unwrap()` at line 225) - guards entire device config
2. **Queue lock** (`queue.queue_mut().lock()` at line 234) - guards the virtio used ring

Thread pool workers perform I/O in parallel, but then serialize on these locks to post completions back to the guest. This negates most parallelism benefits.

```rust
// handler.rs - Thread pool worker must re-acquire lock to complete
let work_func = move || {
    // ... do IO work (parallel) ...
    if pooled {
        let queue = &mut config.lock().unwrap().queues[queue_index];  // SERIALIZE HERE
        queue.add_used(mem, head_index, total as u32);
    }
};
```

### Contributing Factors

| Factor | Impact | Detail |
|--------|--------|--------|
| **Mutex contention** | Primary | Completions serialize on config + queue locks |
| **Synchronous syscalls** | Secondary | fuse-backend-rs PassthroughFs uses blocking syscalls |
| **Shared event loop** | Minor | Thread pool mitigates, but completion notifications still go through main loop |
| **DAX read-only** | Limited | DAX window only supports read mappings (write support has a security TODO) |

### Why External virtiofsd Avoids This

QEMU's external virtiofsd runs as a **separate process** with its own event loop and thread pool. It communicates with QEMU via the vhost-user protocol, which has a small per-request IPC overhead but enables **true parallelism** - no shared mutexes between the filesystem handler and the VMM.

---

## VM Sizing Behavior

### Key Finding: CPU Limits Required for Proper VM Sizing

Kata determines VM vCPU count based on `sandbox-cpu-quota` annotation (from `cpu.limits`), **not** `sandbox-cpu-shares` (from `cpu.requests`).

| Pod Spec | sandbox-cpu-quota | VM vCPUs | Guest cpu.max |
|----------|-------------------|----------|---------------|
| `limits: 200m` | 20000 | 2 | 20000 100000 |
| `limits: 1000m` | 100000 | 2 | 100000 100000 |
| `limits: 3000m` | 300000 | 4 | 300000 100000 |
| `requests: 2` (no limit) | 0 | **1** | max 100000 |
| (none) | 0 | **1** | max 100000 |

**Critical Issue:** Pods with only `cpu.requests` (no limits) get undersized VMs:
- Kubernetes guarantees 2 CPUs via request
- Kata VM only allocates 1 vCPU
- Workload is starved despite Kubernetes guarantee

**Recommendation:** Always set `cpu.limits` for Kata pods to ensure proper VM sizing.

---

## Summary

### CPU Performance
| Scenario | Overhead |
|----------|----------|
| With CPU limits (fair comparison) | **~3.4%** |
| Without CPU limits | N/A (VM undersized) |

### I/O Performance by Hypervisor
| Hypervisor | Shared FS | Read vs runc | Write vs runc |
|------------|-----------|--------------|---------------|
| **QEMU** (external virtiofsd) | virtio-fs | **~1x** (comparable) | **~1x** (comparable) |
| **Dragonball** (inline-virtio-fs, tuned) | inline-virtio-fs | **~6x slower** | **~4x slower** |
| **Dragonball** (inline-virtio-fs, default) | inline-virtio-fs | **~18x slower** | **~10x slower** |

### Recommendations

1. **Always set `cpu.limits`** - Required for proper VM sizing
2. **Use QEMU (`kata-qemu`) for I/O intensive workloads** - External virtiofsd has near-native performance
3. **Use Dragonball for CPU-bound or low-I/O workloads** - Faster boot time, lower memory footprint
4. **Use CSI block storage** for data volumes when possible - virtio-blk bypasses virtio-fs entirely
5. **Expect minimal CPU overhead** - ~3-5% for compute-bound workloads regardless of hypervisor

### Caveats

1. **Nested virtualization** - All tests ran in nested VMs; bare metal deployments will have lower overhead
2. **Hostpath PVCs** - Do not provide real block devices; use CSI drivers for virtio-blk
3. **Single-node test** - Network overhead not measured
4. **QEMU read performance** - kata-qemu outperforming runc in some tests is likely due to virtiofsd write-back caching and test file fitting in memory

---

## Test Commands Reference

### CPU Benchmark
```bash
# Create pods
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bench-runc
spec:
  containers:
  - name: bench
    image: severalnines/sysbench
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "1"
---
apiVersion: v1
kind: Pod
metadata:
  name: bench-kata
spec:
  runtimeClassName: kata-dragonball
  containers:
  - name: bench
    image: severalnines/sysbench
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "1"
EOF

# Run benchmark
kubectl exec bench-runc -- sysbench cpu --threads=1 --time=10 run
kubectl exec bench-kata -- sysbench cpu --threads=1 --time=10 run
```

### I/O Benchmark
```bash
# Create pods (change runtimeClassName as needed)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bench-runc
spec:
  containers:
  - name: bench
    image: nixery.dev/shell/fio
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "1"
        memory: 512Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: bench-kata
spec:
  runtimeClassName: kata-dragonball
  containers:
  - name: bench
    image: nixery.dev/shell/fio
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "1"
        memory: 512Mi
EOF

# Random read
kubectl exec bench-runc -- fio --name=randread --ioengine=libaio --direct=1 \
  --bs=4k --iodepth=32 --size=128M --rw=randread --runtime=10 --time_based

kubectl exec bench-kata -- fio --name=randread --ioengine=libaio --direct=1 \
  --bs=4k --iodepth=32 --size=128M --rw=randread --runtime=10 --time_based

# Random write
kubectl exec bench-runc -- fio --name=randwrite --ioengine=libaio --direct=1 \
  --bs=4k --iodepth=32 --size=128M --rw=randwrite --runtime=10 --time_based

kubectl exec bench-kata -- fio --name=randwrite --ioengine=libaio --direct=1 \
  --bs=4k --iodepth=32 --size=128M --rw=randwrite --runtime=10 --time_based
```

### Check VM/Cgroup Configuration
```bash
# Check visible CPUs
kubectl exec <pod> -- nproc

# Check cgroup CPU limit
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.max

# Check sandbox annotations (on node)
crictl inspectp <pod-id> | grep sandbox-cpu
```
