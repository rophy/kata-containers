# Kata Containers Isolation Test Report

**Date:** 2026-02-05
**Kata Version:** 3.26.0
**Hypervisor:** QEMU (kata-qemu)

## Test Environment

- **Host:** Ubuntu 24.04, Intel i5-4590 (4 cores), nested virtualization
- **VM:** Multipass KVM, 4 vCPUs, 8GB RAM, 30GB disk
- **Container Runtime:** CRI-O 1.33
- **Kubernetes:** v1.33 (MicroK8s)
- **Node kernel:** 6.8.0-90-generic
- **Kata guest kernel:** 6.12.47

## Motivation

In production Kubernetes clusters, "noisy neighbour" pods can destabilize an entire node. Common scenarios include:

- A database with connection leaks exhausting kernel resources
- A runaway process spawning thousands of children (fork bomb)
- Memory-hungry workloads triggering OOM kills of unrelated pods

With **runc**, all containers share the host kernel. A misbehaving container can exhaust shared kernel resources (process table, conntrack table, file descriptors) and affect every other pod on the node.

With **Kata Containers**, each pod runs in its own VM with its own kernel. Kernel-level resource exhaustion is contained within the VM.

---

## Test 1: TCP Port Exhaustion

### Scenario

A pod opens 25,000 outbound TCP connections, consuming ephemeral ports (range: 32768-60999, total: 28,232 ports).

### Setup

- **TCP sink:** Service accepting and holding TCP connections
- **Noisy pod:** Opens 25,000 TCP connections to the sink
- **Victim pod:** Attempts to create TCP connections

### Results (runc)

The noisy pod successfully opened 25,000 connections. However, the **victim pod was NOT affected**:

```
Victim: trying to connect to tcp-sink:9999
  Connection 1: SUCCESS
  Connection 2: SUCCESS
  Connection 3: SUCCESS
  Connection 4: SUCCESS
  Connection 5: SUCCESS
```

### Analysis

**TCP port exhaustion does not cross pod boundaries even with runc.** Kubernetes creates a separate network namespace per pod, so each pod has its own pool of 28,232 ephemeral ports. The 25,000 connections from the noisy pod only consumed ports in its own network namespace.

This test demonstrates that Kubernetes' built-in network namespace isolation already handles TCP port exhaustion. Kata's VM-level isolation is not needed for this specific scenario.

> **Note:** This does NOT apply when pods use `hostNetwork: true`, which bypasses per-pod network namespaces. In that case, TCP port exhaustion would be a real cross-pod issue.

---

## Test 2: Fork Bomb (Process Table Exhaustion)

### Scenario

A pod continuously forks child processes that perform a short CPU computation before exiting. This saturates the host kernel's process scheduler and process table.

### Setup

- **Noisy pod:** Continuous fork+compute loop (no CPU limits, simulating misconfiguration)
- **Victim pod:** Measures fork+exec latency (`subprocess.run(['echo', 'ping'])`)
- Tests run with both runc and kata-qemu

### Test Code

**Noisy pod (fork bomb):**
```python
import os, signal
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
while True:
    pid = os.fork()
    if pid == 0:
        s = 0
        for x in range(100000):
            s += x
        os._exit(0)
```

**Victim pod (latency measurement):**
```python
import subprocess, time
times = []
for i in range(20):
    start = time.monotonic()
    subprocess.run(['echo', 'ping'], capture_output=True)
    elapsed = (time.monotonic() - start) * 1000
    times.append(elapsed)
```

### Results

#### Victim Fork+Exec Latency (P50)

| Scenario | runc | kata-qemu |
|----------|------|-----------|
| Baseline (no stress) | **0.9ms** | 15.8ms |
| Under fork bomb | **1.1ms** | 16.5ms |
| Degradation | +22% | +4% |

#### Host Node Impact

| Metric | runc | kata-qemu |
|--------|------|-----------|
| **Host load average** | **41** | **2.1** |
| **Peak host load (earlier test)** | **683** | N/A |
| **Host process visibility** | Fork bomb children visible | Only QEMU process visible |

### Analysis

The critical difference is at the **host kernel level**, not within the victim pod:

**runc:**
- The fork bomb's children are created in the **host kernel's process table**
- Host load spiked to **41** (on a 4-CPU node), with peaks of **683** in earlier tests
- All node processes (kubelet, CRI-O, kube-proxy, other pods) compete with the fork bomb for scheduler time
- The victim pod's latency appeared similar only because the fork bomb was CPU-throttled by cgroup limits in some runs
- Without CPU limits, the node became severely degraded: `kubectl` commands took seconds, API server had timeouts

**kata-qemu:**
- The fork bomb runs entirely inside the **guest VM's kernel**
- Host sees only 1 QEMU process per pod - the fork bomb is invisible
- Host load stayed at **2.1** - completely unaffected
- The fork bomb can exhaust the guest VM's pid_max but **cannot touch the host kernel**

**Trade-off:** Kata's baseline fork+exec latency is ~16x higher (15.8ms vs 0.9ms) due to VM overhead. This is the cost of kernel-level isolation.

### Key Observations

1. **CPU limits partially mitigate runc fork bombs** - With `limits.cpu: "1"`, the fork bomb was throttled and had minimal impact. Without limits, the node was severely affected.

2. **Kata provides defense-in-depth** - Even without CPU limits on the pod, the fork bomb cannot escape the VM. This protects against misconfigured pods.

3. **Earlier 10,000-sleep-process test** drove host load to **64** with runc, despite processes being idle (sleeping). The scheduler overhead of managing thousands of processes in the host kernel was enough to degrade the node.

---

## Test 3: Conntrack Table Exhaustion

### Scenario

In Kubernetes, every connection through a Service (ClusterIP) creates an entry in the host kernel's `nf_conntrack` table. This table has a fixed maximum size (typically 65,536 or 131,072 entries). When exhausted, **all new connections on the node fail** - including kubelet health checks, DNS, and inter-pod traffic.

### Setup

- **TCP sink:** Pod with a Service (ClusterIP `tcp-sink:9999`)
- **Client pods:** One runc, one kata-qemu, each opening 100 TCP connections **via the Service**
- **Measurement:** `conntrack -L -p tcp --dport 9999 | wc -l` on the node

### Results

| Client | Connections | Host conntrack delta |
|--------|-------------|---------------------|
| **runc** | 100 | **+100 entries** |
| **kata-qemu** | 100 | **+100 entries** |

### Analysis

**Kata does NOT isolate conntrack.** Both runc and kata create the same number of conntrack entries on the host kernel.

This is because Kubernetes Service resolution (ClusterIP → iptables DNAT → backend Pod) runs in the **host kernel's netfilter** stack, regardless of whether the source pod runs in a VM:

```
runc pod:     pod netns → veth → host netns → iptables/conntrack → destination
kata pod:     VM → tap → tcfilter → host netns → iptables/conntrack → destination
```

Both paths pass through host iptables for Service DNAT, creating conntrack entries on the host.

**Conntrack table exhaustion is a shared resource problem that neither runc nor Kata isolates.**

---

## Test 4: Inode Exhaustion

### Scenario

Every file on a filesystem consumes an inode. If a pod creates millions of small files, it can exhaust the node's inode pool, preventing any process on the node from creating new files - including kubelet, container runtime logs, and other pods.

### Setup

- **runc and kata-qemu pods** each create 10,000 files on the container rootfs (`/tmp`)
- **Measurement:** `df -i /` on the node before and after

### Results

| Action | Host inode delta (runc) | Host inode delta (kata) |
|--------|------------------------|------------------------|
| Create 10,000 files on rootfs (`/tmp`) | **+10,002** | **+10,002** |
| Create 10,000 files on PVC (hostpath) | **+10,000** | **+10,001** |
| Create 10,000 files on PVC (LVM block device) | **0** | **0** |
| Create 10,000 files on `/dev/shm` (guest tmpfs) | N/A | **0** |

### Analysis

**Kata does NOT isolate inodes** for rootfs or hostpath PVC writes. Both runc and kata consume host inodes 1:1.

- **Container rootfs:** Shared via virtio-fs from the host's overlay filesystem
- **PVC (hostpath):** Stored directly on the host filesystem, mounted into kata via virtio-fs
- **PVC (LVM block device):** Each LVM volume has its own ext4 filesystem with an independent inode pool (16,384 inodes for 64MB). Host inode count is unaffected regardless of runtime. This is CSI-level isolation, not Kata isolation.
- **Guest-local tmpfs:** Files on `/dev/shm` inside the VM exist only in VM memory and do NOT consume host inodes

The hostpath provisioner stores PVC data directly on the host filesystem, so inodes are consumed on the host regardless of runtime. Block-device CSI drivers (e.g., OpenEBS LVM LocalPV) provide inode isolation by giving each PVC its own filesystem.

---

## Test 5: Information Leak via /proc and /sys

### Scenario

With runc, containers share the host kernel and can read sensitive information from `/proc` and `/sys`. While some paths are masked or read-only, many still expose host-level details. With Kata, all `/proc` and `/sys` entries reflect the guest VM, not the host.

### Results

#### Memory Visibility (`/proc/meminfo`)

| Source | MemTotal |
|--------|----------|
| **Host** | 8,125,984 kB (8 GB) |
| **runc pod** | **8,125,984 kB** (host value leaked) |
| **kata pod** | 1,971,700 kB (VM allocation only) |

The runc pod sees the full host memory. A malicious container can determine the node's total RAM and usage patterns.

#### CPU Visibility (`/proc/cpuinfo`)

| Source | Processors |
|--------|------------|
| **Host** | 4 |
| **runc pod** | **4** (host value leaked) |
| **kata pod** | 1 (VM vCPU only) |

#### Kernel Version (`uname -r`)

| Source | Kernel |
|--------|--------|
| **Host** | 6.8.0-90-generic |
| **runc pod** | **6.8.0-90-generic** (host kernel leaked) |
| **kata pod** | 6.18.5 (guest kernel) |

A runc container can fingerprint the exact host kernel version, which is useful for identifying kernel exploits.

#### Disk Partitions (`/proc/partitions`)

| Source | Devices |
|--------|---------|
| **runc pod** | **sda, sda1, sda14, sda15, sda16, loop0-2, sr0, fd0** (host devices) |
| **kata pod** | ram0-15, pmem0, pmem0p1 (VM virtual devices only) |

The runc pod can see the host's physical disk layout, including partition sizes.

#### Kernel Modules (`/proc/modules`)

| Source | Result |
|--------|--------|
| **runc pod** | **Accessible** - lists all host kernel modules (ipt_REJECT, tls, xfrm, etc.) |
| **kata pod** | Not accessible |

Exposes the host's loaded kernel modules, useful for attack surface enumeration.

#### Kernel Symbols (`/proc/kallsyms`)

| Source | Symbols |
|--------|---------|
| **runc pod** | **238,573** symbols (host kernel) |
| **kata pod** | 40,578 symbols (guest kernel) |

Host kernel symbols can aid in developing kernel exploits (bypassing KASLR).

#### DMI/BIOS Info (`/sys/class/dmi/id/product_name`)

| Source | Value |
|--------|-------|
| **Host** | Standard PC (i440FX + PIIX, 1996) |
| **runc pod** | **Standard PC (i440FX + PIIX, 1996)** (host value) |
| **kata pod** | Not accessible |

### Analysis

runc containers can read extensive host information through `/proc` and `/sys`:
- **Host memory size and usage** - capacity planning intelligence
- **CPU count and model** - hardware fingerprinting
- **Kernel version** - exploit targeting
- **Disk layout** - storage enumeration
- **Kernel modules and symbols** - attack surface mapping

Kata pods see only their VM's virtual hardware. The guest kernel is different, memory is VM-scoped, disk devices are virtual, and host kernel internals are completely hidden.

---

## Test 6: File Descriptor Exhaustion

### Scenario

The host kernel maintains a system-wide count of open file descriptors (`/proc/sys/fs/file-nr`). Every file open, socket creation, or pipe in a runc container increments this global counter. If a pod opens enough file descriptors, it can exhaust the system-wide limit, causing "too many open files" errors for all processes on the node.

### Setup

- **runc and kata-qemu pods** each open 10,000 file descriptors (`/dev/null`)
- **Measurement:** `cat /proc/sys/fs/file-nr` on the node before and after

### Results

| Client | FDs opened | Host file-nr delta |
|--------|-----------|-------------------|
| **runc** | 10,000 | **+10,176** |
| **kata-qemu** | 10,000 | **+608** (kubectl exec overhead) |

### Analysis

**Kata isolates file descriptors.** File descriptors opened inside a kata pod exist in the guest kernel and do not consume host file descriptors. The small host delta (~608) during the kata test is from the `kubectl exec` session itself, not from the 10,000 fds opened inside the VM.

With runc, all file descriptors are in the host kernel. A pod opening 10,000 fds causes a 1:1 increase in the host's global fd count.

---

## Test 7: Inotify Watch Exhaustion

### Scenario

The host kernel has a system-wide limit on inotify watches (`/proc/sys/fs/inotify/max_user_watches`, default 1,048,576). Applications using file watchers (node.js dev servers, IDEs, log tailers) create inotify watches. If a pod exhausts the limit, other pods and system services cannot create new watches, resulting in "no space left on device" errors.

### Setup

- **runc and kata-qemu pods** each create 1,000 inotify watches on files in `/tmp`
- **Measurement:** Count total inotify watches across all host processes via `/proc/*/fdinfo/*`

### Results

| Client | Watches created | Host inotify watch delta |
|--------|----------------|-------------------------|
| **runc** | 1,000 | **+998** |
| **kata-qemu** | 1,000 | **+6** (background noise) |

### Analysis

**Kata isolates inotify watches.** Inotify watches created inside a kata pod exist in the guest kernel and do not consume host inotify watches. The host count remained essentially unchanged (+6 from background fluctuation).

With runc, inotify watches are in the host kernel. A pod creating 1,000 watches causes a 1:1 increase in the host's global watch count.

---

## Summary

### Isolation Properties: runc vs Kata

| Resource | runc Isolation | Kata Isolation |
|----------|---------------|----------------|
| **Network (TCP ports)** | Isolated (per-pod netns) | Isolated (per-VM netns) |
| **Conntrack table** | **Shared host kernel** | **Shared host kernel** |
| **Filesystem inodes (hostpath)** | **Shared host filesystem** | **Shared via virtio-fs** |
| **Filesystem inodes (LVM PVC)** | Isolated (per-PVC filesystem) | Isolated (per-PVC filesystem) |
| **File descriptors** | **Shared host kernel** | Isolated (per-VM kernel) |
| **Inotify watches** | **Shared host kernel** | Isolated (per-VM kernel) |
| **Process table (PIDs)** | **Shared host kernel** | Isolated (per-VM kernel) |
| **Kernel scheduler** | **Shared** | Isolated |
| **Kernel memory (slab, page tables)** | **Shared** | Isolated |
| **Kernel crash** | **Takes down all pods** | Contained to one VM |
| **/proc, /sys visibility** | **Host info leaked** | VM-scoped |

### When Kata Isolation Matters

1. **Untrusted workloads** - Running third-party or user-submitted code
2. **Missing resource limits** - Defense against misconfigured pods (no CPU/memory limits, no PID limits)
3. **Kernel-level attacks** - Protection against container escape via kernel exploits
4. **Compliance requirements** - Workloads requiring hard isolation boundaries (e.g., multi-tenant SaaS)

### When runc Is Sufficient

1. **Trusted workloads** with proper resource limits (CPU, memory, PID)
2. **Performance-sensitive** workloads that cannot tolerate VM overhead (~16x fork latency, ~3% CPU)
3. **Single-tenant** clusters where all workloads are from the same trust domain

---

## Test Commands Reference

### Fork Bomb Test

```bash
# TCP sink + service
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: victim
spec:
  # runtimeClassName: kata-qemu  # uncomment for kata test
  containers:
  - name: victim
    image: python:3-slim
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "500m"
        memory: 256Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: noisy
spec:
  # runtimeClassName: kata-qemu  # uncomment for kata test
  containers:
  - name: noisy
    image: python:3-slim
    command:
    - python3
    - -c
    - |
      import os, time, signal
      signal.signal(signal.SIGCHLD, signal.SIG_IGN)
      count = 0
      while True:
          try:
              pid = os.fork()
              if pid == 0:
                  s = 0
                  for x in range(100000):
                      s += x
                  os._exit(0)
              else:
                  count += 1
                  if count % 10000 == 0:
                      print(f"Forked {count}", flush=True)
          except OSError as e:
              print(f"Fork failed: {e}", flush=True)
              time.sleep(0.1)
    resources:
      requests:
        cpu: "100m"
        memory: 256Mi
EOF

# Monitor host load
watch -n1 'cat /proc/loadavg'

# Measure victim fork latency
kubectl exec victim -- python3 -c "
import subprocess, time
times = []
for i in range(20):
    start = time.monotonic()
    subprocess.run(['echo', 'ping'], capture_output=True)
    elapsed = (time.monotonic() - start) * 1000
    times.append(elapsed)
avg = sum(times) / len(times)
p50 = sorted(times)[len(times)//2]
print(f'Avg: {avg:.1f}ms, P50: {p50:.1f}ms, Max: {max(times):.1f}ms')
"
```
