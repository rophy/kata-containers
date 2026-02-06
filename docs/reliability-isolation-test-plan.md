# Reliability Isolation Test Plan

**Objective:** Measure which host-level kernel resources are isolated by Kata Containers (kata-qemu) vs shared with host when using runc.

**Method:** For each resource, create entries from inside a pod and measure the delta on the host. No stress testing - just verify whether the resource is host-shared or VM-isolated.

**Environment:**
- Host: Multipass VM (microk8s-crio), 4 vCPU, 8GB RAM
- Kubernetes: MicroK8s 1.33, CRI-O 1.33
- Kata: 3.26.0, kata-qemu (QEMU + external virtiofsd)
- Comparison: runc vs kata-qemu

---

## Already Tested

| # | Resource | Result | Report |
|---|----------|--------|--------|
| 1 | TCP ephemeral ports | Isolated by netns (both runc and kata) | isolation-test-report.md |
| 2 | PIDs / scheduler | Kata isolates; runc shares host kernel | isolation-test-report.md |
| 3 | Conntrack table | Shared (both runc and kata) | isolation-test-report.md |
| 4 | Inodes (rootfs, PVC) | Shared via virtio-fs (both runc and kata) | isolation-test-report.md |
| 5 | /proc, /sys info leak | Kata isolates; runc leaks host info | isolation-test-report.md |

---

## New Tests

### Test 6: File Descriptors (system-wide)

**Resource:** `fs.file-max` — system-wide limit on open file descriptors.

**Why it matters:** A pod opening many files or sockets consumes from the host's global fd pool. Exhaustion causes "too many open files" errors for all processes on the node.

**Measure:**
- Read host `/proc/sys/fs/file-nr` before and after
- Pod opens 10,000 files (or sockets) inside the container
- Compare host fd count delta: runc vs kata

**Expected:**
- runc: host fd count increases
- kata: host fd count does not increase (fds are in guest kernel)

---

### Test 7: Inotify Watches

**Resource:** `fs.inotify.max_user_watches` — system-wide limit on inotify watches.

**Why it matters:** Applications using file watchers (node.js dev servers, IDEs, log tailers) create inotify watches. Exhaustion causes "no space left on device" errors when creating new watches.

**Measure:**
- Read host `/proc/sys/fs/inotify/max_user_watches` and current usage
- Pod creates 1,000 inotify watches on files in `/tmp`
- Compare host inotify watch count delta: runc vs kata

**Host measurement:**
```bash
# Total watches across all processes
cat /proc/sys/fs/inotify/max_user_watches
find /proc/*/fdinfo -name '*.fdinfo' 2>/dev/null | xargs grep -c inotify 2>/dev/null
# Or:
sysctl fs.inotify
```

**Expected:**
- runc: host inotify watch count increases
- kata: host inotify watch count does not increase

---

### Test 8: Inotify Instances

**Resource:** `fs.inotify.max_user_instances` — limit on inotify instances per user.

**Why it matters:** Each `inotify_init()` call creates an instance. Applications like container runtimes, log agents, and monitoring tools each create instances.

**Measure:**
- Read host inotify instance count before and after
- Pod creates 100 inotify instances
- Compare host delta: runc vs kata

**Expected:**
- runc: host instance count increases
- kata: host instance count does not increase

---

### Test 9: ARP / Neighbour Table

**Resource:** `net.ipv4.neigh.default.gc_thresh3` — max entries in the ARP cache.

**Why it matters:** Each unique IP a pod communicates with adds an ARP entry. In large clusters with many services, this table can fill up, causing "neighbour table overflow" errors and packet drops.

**Measure:**
- Read host `ip neigh show | wc -l` before and after
- Pod pings or connects to multiple IPs (e.g., 50 unique IPs via DNS or generated)
- Compare host ARP table delta: runc vs kata

**Note:** ARP table may be per-netns already. Test will verify this.

**Expected:**
- If per-netns: both runc and kata isolated (same as TCP ports)
- If host-shared: runc increases host table, kata does not

---

### Test 10: Mount Points

**Resource:** Host mount table (`/proc/mounts`).

**Why it matters:** Each container creates several mount points (overlay, proc, sys, tmpfs, volumes). A pod creating mounts inside the container may or may not affect the host mount table.

**Measure:**
- Read host `cat /proc/mounts | wc -l` before and after pod creation
- Count mount delta per pod: runc vs kata
- Optionally: create additional bind mounts inside the pod

**Expected:**
- runc: host mount count increases (overlay + volume mounts)
- kata: host mount count increases (virtio-fs share mounts)

---

### Test 11: Disk Space

**Resource:** Host filesystem free space.

**Why it matters:** Container rootfs writes and PVC writes consume host disk. If one pod fills the disk, other pods can't write logs, create files, or pull images.

**Measure:**
- Read host `df -h /` before and after
- Pod writes a 100MB file to rootfs (`/tmp`) and to PVC
- Compare host disk usage delta: runc vs kata

**Expected:**
- runc: host disk usage increases
- kata: host disk usage increases (rootfs shared via virtio-fs)

---

### Test 12: Dentry / Inode Cache (Slab Memory)

**Resource:** Kernel slab allocator — `dentry` and `inode_cache` entries.

**Why it matters:** Every file access (open, stat, readdir) creates dentry and inode cache entries in the kernel. A pod doing heavy filesystem traversal (e.g., `find /`) grows the host kernel's slab memory.

**Measure:**
- Read host `slabtop -o | grep -E "dentry|inode_cache"` before and after
- Pod runs `find / -type f 2>/dev/null | wc -l` to generate dentry cache entries
- Compare host slab delta: runc vs kata

**Expected:**
- runc: host dentry/inode_cache grows
- kata: host dentry/inode_cache may still grow (virtio-fs creates host-side dentries)

---

### Test 13: Socket Buffer Memory

**Resource:** `net.core.rmem_max`, `net.core.wmem_max`, `net.ipv4.tcp_mem` — kernel network buffer memory.

**Why it matters:** Each TCP connection consumes kernel memory for send/receive buffers. A pod with thousands of connections consumes kernel network memory that's shared with all processes.

**Measure:**
- Read host `cat /proc/net/sockstat` before and after
- Pod opens 1,000 TCP connections with data in flight
- Compare host TCP memory delta: runc vs kata

**Expected:**
- runc: host TCP memory (mem field in sockstat) increases
- kata: host TCP memory does not increase

---

### Test 14: Entropy Pool

**Resource:** `/dev/random` entropy — `cat /proc/sys/kernel/random/entropy_avail`.

**Why it matters:** TLS handshakes and cryptographic operations consume entropy. A pod doing many TLS connections can drain the entropy pool, causing `/dev/random` to block for other pods.

**Measure:**
- Read host entropy_avail before and after
- Pod reads 1MB from `/dev/random`
- Compare host entropy_avail delta: runc vs kata

**Note:** Modern kernels (5.6+) use CRNG and `/dev/random` no longer blocks. This test may show no difference on modern kernels. Verify kernel behavior first.

**Expected:**
- Modern kernels: likely no observable difference (CRNG reseeds)
- Older kernels: runc drains host entropy, kata does not

---

## Summary Table

| # | Resource | Kernel limit | Cgroup protection | Kata isolation | Status |
|---|----------|-------------|-------------------|----------------|--------|
| 6 | File descriptors | `fs.file-max` | None | **Yes** | Tested |
| 7 | Inotify watches | `fs.inotify.max_user_watches` | None | **Yes** | Tested |
| 8 | Inotify instances | `fs.inotify.max_user_instances` | None | **Yes** | Tested |
| 9 | ARP table | `neigh/default/gc_thresh3` | None | N/A (per-netns) | Tested |
| 10 | Mount points | soft (memory) | None | Partial | |
| 11 | Disk space | filesystem size | None (quota only) | **No** | Tested |
| 12 | Dentry/inode cache | slab memory | memory cgroup (partial) | **No** (virtio-fs) | Tested |
| 13 | Socket buffer memory | `net.ipv4.tcp_mem` | memory cgroup (partial) | Yes | |
| 14 | Entropy pool | pool size | None | TBD (modern kernels) | |
