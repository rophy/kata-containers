# Kata Containers Isolation Test Report: Guest Pull Mode

**Date:** 2026-03-29
**Kata Version:** 3.26.0
**Hypervisor:** QEMU (kata-qemu-coco-dev)
**Mode:** `shared_fs=none` + `experimental_force_guest_pull=true`

## Test Environment

- **Host:** Ubuntu 24.04, Multipass VM, 4 vCPUs, 8GB RAM, 30GB disk
- **Container Runtime:** CRI-O 1.33.10 with `runtime_pull_image = true`
- **Kubernetes:** v1.33 (MicroK8s)
- **Node kernel:** 6.8.0-106-generic
- **Kata guest kernel:** 6.18.5

## Motivation

The [previous isolation test report](isolation-test-report.md) identified three disk-related resources that Kata with virtio-fs **could not isolate**: inodes, disk space, and dentry/inode slab cache. This was because the container rootfs was shared from the host filesystem via virtio-fs — every file operation inside the VM translated to a host filesystem operation.

This report tests a different architecture: **guest pull** mode, where the container image is pulled and unpacked inside the guest VM itself. With `shared_fs=none`, no virtio-fs is used for the rootfs. The goal is to verify whether this eliminates the disk isolation gaps.

### How Guest Pull Works

```
Traditional (virtio-fs):
  Host pulls image → host overlay fs → virtio-fs → guest mounts host rootfs

Guest pull (shared_fs=none):
  Host tells guest "pull busybox:latest" → guest pulls image via network →
  guest unpacks layers to /run/kata-containers/image/layers/ → guest overlay fs
```

With guest pull, the container rootfs exists entirely inside the VM. The host filesystem is not involved in serving container files.

---

## Test 1: Inode Exhaustion (Rootfs)

### Scenario

Create 10,000 files on the container rootfs (`/tmp`) and measure host inode consumption.

### Results

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Host inodes used | 103,057 | 103,057 | **+0** |

### Comparison with virtio-fs

| Mode | Host inode delta |
|------|-----------------|
| virtio-fs (old report) | **+10,002** |
| Guest pull | **+0** |

### Analysis

**Guest pull fully isolates inodes.** Files created inside the container exist on the guest VM's own filesystem (overlay on `/run/kata-containers/image/layers/`). No host inodes are consumed.

With virtio-fs, the container rootfs was an overlay on the host filesystem, so every file creation consumed a host inode 1:1.

---

## Test 2: Disk Space

### Scenario

Write a 100MB file to `/tmp` inside the container and measure host disk consumption.

### Results

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Host disk used (MB) | 10,927 | 10,927 | **+0** |

### Comparison with virtio-fs

| Mode | Host disk delta |
|------|-----------------|
| virtio-fs (old report) | **+100 MB** |
| Guest pull | **+0** |

### Analysis

**Guest pull fully isolates disk space.** The 100MB file exists only in the guest VM's memory/virtual disk. No host disk is consumed.

With virtio-fs, writes to the container rootfs went through virtio-fs to the host overlay filesystem, consuming host disk 1:1.

---

## Test 3: Dentry / Inode Cache (Slab Memory)

### Scenario

Create and `stat()` 10,000 files on `/tmp` inside the container and measure host kernel slab cache growth.

### Results

| Slab object | Before | After | Delta |
|-------------|--------|-------|-------|
| dentry | 72,744 | 72,765 | **+21** (noise) |
| ext4_inode_cache | 15,948 | 15,948 | **+0** |

### Comparison with virtio-fs

| Mode | dentry delta | ext4_inode delta |
|------|-------------|-----------------|
| virtio-fs (old report) | **+29,997** | **+10,012** |
| Guest pull | **+21** (noise) | **+0** |

### Analysis

**Guest pull fully isolates slab cache.** With virtio-fs, the host kernel created dentry and inode cache entries to serve each file request from the guest via virtiofsd. With guest pull, no host filesystem operations occur for container file access, so the host slab caches are unaffected.

---

## Test 4: File Descriptor Exhaustion

### Scenario

Open 10,000 file descriptors (`/dev/null`) inside the container and measure host file-nr.

### Results

| Metric | Before | During | Delta |
|--------|--------|--------|-------|
| Host file-nr (alloc) | 1,696 | 1,824 | **+128** (exec overhead) |

### Analysis

**Isolated.** The +128 is from the `kubectl exec` session infrastructure (multipass, kubectl, shim), not from the 10,000 fds opened inside the VM. This is consistent with the previous virtio-fs report where kata also showed only exec overhead (+608).

---

## Test 5: Inotify Watches and Instances

### Scenario

Create 1,000 inotify watches and 100 inotify instances inside the container. Measure host inotify instance count.

### Results

| Metric | Before | During | Delta |
|--------|--------|--------|-------|
| Host inotify instances | 44 | 44 | **+0** |

### Analysis

**Isolated.** Inotify watches and instances exist in the guest kernel. Consistent with the virtio-fs report.

---

## Test 6: Conntrack Table

### Scenario

Open 100 TCP connections from the kata pod to a Service (ClusterIP), measuring host conntrack entries.

### Results

| Metric | Before | During | Delta |
|--------|--------|--------|-------|
| Host conntrack count | 113 | 321 | **+208** |

### Analysis

**Still shared.** Conntrack entries are created in the host kernel's netfilter stack regardless of runtime or guest pull mode, because Kubernetes Service DNAT (ClusterIP → iptables → backend Pod) runs in the host network namespace:

```
kata pod → VM tap → host netns → iptables/conntrack (DNAT) → destination pod
```

Guest pull does not change the networking path. This is the same result as the virtio-fs report.

---

## Test 7: Mount Points

### Scenario

Measure host mount count before and after creating a kata pod.

### Results

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Host mount count | 55 | 62 | **+7** |

### Analysis

**Shared** — the host still creates mounts for each pod (tmpfs, overlay, namespace mounts). This is managed by CRI-O on the host side, not inside the container or VM. The +7 is comparable to the previous report (+7 for runc, +8 for kata with virtio-fs). Guest pull eliminates one mount (no virtiofsd-related mount needed) but the difference is minor.

---

## Test 8: Socket Buffer Memory

### Scenario

Create 1,000 socket pairs with 4KB of data per connection inside the container. Measure host TCP memory.

### Results

| Metric | Before | During | Delta |
|--------|--------|--------|-------|
| TCP alloc | 52 | 59 | **+7** (noise) |
| TCP mem (pages) | 0 | 0 | **+0** |

### Analysis

**Isolated.** Socket buffers exist entirely in the guest kernel. Consistent with the virtio-fs report.

---

## Test 9: /proc and /sys Information Leak

### Results

| Resource | Host | Kata Pod (guest pull) |
|----------|------|-----------------------|
| MemTotal | 8,125,976 kB (8 GB) | 1,973,200 kB (~2 GB VM) |
| CPUs | 4 | 1 |
| Kernel | 6.8.0-106-generic | 6.18.5 |
| Partitions | sda, sr0, fd0 | pmem0, dm-0 (virtual) |
| Kernel modules | 109 | 0 |
| Kallsyms | 238,855 | 42,382 |
| DMI/BIOS | accessible | not accessible |

### Analysis

**Fully isolated.** The pod sees only VM-scoped information. Consistent with the virtio-fs report.

---

## Summary

### What Guest Pull Fixes

The three disk-related isolation gaps from the virtio-fs architecture are fully resolved:

| Resource | virtio-fs | Guest Pull | Improvement |
|----------|-----------|------------|-------------|
| **Filesystem inodes** | Shared (1:1 host consumption) | **Isolated** | Host inodes unaffected |
| **Disk space** | Shared (1:1 host consumption) | **Isolated** | Host disk unaffected |
| **Dentry/inode slab cache** | Shared (host kernel caches grow) | **Isolated** | Host slab unaffected |

### Full Isolation Matrix

| Resource | runc | Kata (virtio-fs) | Kata (guest pull) |
|----------|------|-------------------|-------------------|
| **Filesystem inodes** | Shared | **Shared** | **Isolated** |
| **Disk space** | Shared | **Shared** | **Isolated** |
| **Dentry/inode slab** | Shared | **Shared** | **Isolated** |
| **Conntrack table** | Shared | Shared | Shared |
| **Mount points** | Shared (+7) | Shared (+8) | Shared (+7) |
| File descriptors | Shared | Isolated | Isolated |
| Inotify watches | Shared | Isolated | Isolated |
| Inotify instances | Shared | Isolated | Isolated |
| Socket buffer memory | Shared | Isolated | Isolated |
| Process table / scheduler | Shared | Isolated | Isolated |
| /proc, /sys visibility | Host leaked | VM-scoped | VM-scoped |
| Network (TCP ports) | Isolated (netns) | Isolated | Isolated |
| ARP table | Isolated (netns) | Isolated | Isolated |

### Trade-offs

**Added latency:** Container images are pulled inside the guest VM over the network. For `busybox:latest` (~2MB), this added ~7 seconds. For `python:3-slim` (~50MB), startup was still under 30 seconds. Larger images will take proportionally longer.

**VM memory consumption:** The unpacked image layers consume guest VM memory/disk instead of host disk. The default VM memory allocation (2GB) must be sufficient for the image plus application.

**Experimental status:** `experimental_force_guest_pull` is labeled experimental. It is actively tested upstream for CoCo (confidential computing) scenarios but is not yet considered stable for general use.

### Configuration

**CRI-O runtime config** (`/etc/crio/crio.conf.d/50-kata.conf`):
```toml
[crio.runtime.runtimes.kata-qemu-coco-dev]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml"
  runtime_pull_image = true
```

**Key Kata config settings** (`configuration-qemu-coco-dev.toml`):
```toml
shared_fs = "none"
experimental_force_guest_pull = true
disable_guest_empty_dir = false
```

**Container rootfs inside VM:**
```
overlay on / type overlay (
  lowerdir=/run/kata-containers/image/layers/0,
  upperdir=/run/kata-containers/image/overlay/<id>/upperdir,
  workdir=/run/kata-containers/image/overlay/<id>/workdir
)
```
