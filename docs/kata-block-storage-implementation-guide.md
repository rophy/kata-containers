# Kata Containers Block Storage Implementation Guide

**Date:** 2026-03-30
**Status:** Design proposal
**Prerequisites:** [Block Storage Support Research](block-storage-research.md), [Guest Pull Isolation Report](isolation-test-report-guest-pull.md)

## Goal

Enable stateful workloads (databases, message queues) to run in Kata Containers VMs with full disk isolation, using any standard block-based CSI driver (Ceph RBD, NetApp Trident, AWS EBS) without modification.

## Problem Statement

Kata Containers' default rootfs delivery uses virtio-fs, which shares the host filesystem into the guest VM. All file operations — both container rootfs and PVC data — go through the host kernel, consuming host inodes, disk space, and slab cache. This creates noisy-neighbor risk for multi-tenant clusters.

With `shared_fs=none` + `force_guest_pull`, the container rootfs is fully isolated (see [guest pull isolation report](isolation-test-report-guest-pull.md)). However, standard `volumeMode: Filesystem` PVCs break — the CSI driver mounts the filesystem on the host, but with no virtio-fs, the mount becomes tmpfs inside the VM and data is lost.

## Chosen Approach: `volumeMode: Block` + Mutating Webhook

After evaluating four approaches (see [research](block-storage-research.md#cri-o-disk-isolation-options)), we chose `volumeMode: Block` with a mutating webhook because:

- **No CSI driver modification** — works with any block CSI unchanged
- **No host unmount** — CSI never mounts the filesystem on the host, so health checks and lifecycle operations work normally
- **Clean separation** — host manages block device attachment, guest manages filesystem
- **Kubernetes-native** — uses standard `volumeMode: Block` feature (GA since K8s 1.18)
- **Already proven** — Ceph RBD block device successfully passed into Kata VM and mounted (tested 2026-03-30)

### Alternative approaches considered

| Approach | Why not |
|----------|---------|
| CSI gRPC proxy | Must unmount host staging path; breaks CSI health checks |
| Kata shim modification | Same unmount problem; requires upstream contribution |
| Direct volume CSI wrapper | Per-driver wrapper needed; operational complexity |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Kubernetes API                                          │
│                                                         │
│  PVC (volumeMode: Block)     Pod (runtimeClass: kata)   │
│         │                           │                   │
│         ▼                           ▼                   │
│  CSI Driver (Ceph/NetApp/EBS)   Mutating Webhook        │
│  - attaches block device        - translates volumeMounts│
│  - NO host format/mount           to volumeDevices      │
│  - /dev/rbdX on node            - adds fsType annotation│
│         │                           │                   │
│         ▼                           ▼                   │
│  kubelet passes block device    Pod spec with            │
│  path to CRI                    volumeDevices            │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ CRI-O                                                   │
│  - passes block device path to Kata shim                │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Kata Shim                                               │
│  - detects block device (S_IFBLK)                       │
│  - attaches to VM via virtio-blk or virtio-scsi         │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Kata Guest VM                                           │
│                                                         │
│  Agent:                                                 │
│  - receives block device (/dev/sdX or /dev/vdX)         │
│  - blkid: check for existing filesystem                 │
│  - mkfs if first use (fsType from annotation)           │
│  - mount at container's requested path                  │
│                                                         │
│  Container:                                             │
│  - sees /data as a normal mounted filesystem            │
│  - unaware of block device mechanics                    │
└─────────────────────────────────────────────────────────┘
```

## Components to Build

### Component 1: Mutating Webhook

**Purpose:** Automatically translate pod specs so that PVCs are consumed as block devices when running on Kata.

**Trigger:** Pods with a Kata RuntimeClass (e.g., `kata-qemu-coco-dev`).

**Behavior:**

For each `volumeMount` backed by a PVC:
1. Check if the PVC's `volumeMode` is `Block`
2. If yes, convert the `volumeMount` entry to a `volumeDevice` entry
3. Set the `devicePath` to a deterministic path (e.g., `/dev/kata-vol-{pvc-name}`)
4. Add an annotation with the desired fsType and mount path:
   ```
   io.katacontainers.volume.{pvc-name}.fsType: ext4
   io.katacontainers.volume.{pvc-name}.mountPath: /data
   ```
5. Leave non-PVC mounts untouched (ConfigMaps, Secrets, emptyDir)

**What the webhook does NOT do:**
- Does not modify the PVC itself (PVC must already be `volumeMode: Block`)
- Does not interact with the CSI driver
- Does not run inside the VM

**Example transformation:**

Before webhook:
```yaml
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - name: postgres
    volumeMounts:
    - name: pgdata
      mountPath: /var/lib/postgresql/data
  volumes:
  - name: pgdata
    persistentVolumeClaim:
      claimName: pg-data
```

After webhook:
```yaml
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - name: postgres
    volumeDevices:
    - name: pgdata
      devicePath: /dev/kata-vol-pgdata
  volumes:
  - name: pgdata
    persistentVolumeClaim:
      claimName: pg-data
  metadata:
    annotations:
      io.katacontainers.volume.pgdata.fsType: "ext4"
      io.katacontainers.volume.pgdata.mountPath: "/var/lib/postgresql/data"
```

### Component 2: Kata Agent Enhancement

**Purpose:** Automatically format (if needed) and mount block devices exposed via `volumeDevices` at the path specified by annotations.

**Current behavior:** `volumeDevices` exposes the raw block device at `devicePath` inside the container. The application must handle it directly.

**Enhanced behavior:** When the agent sees a `volumeDevice` with a corresponding `io.katacontainers.volume.{name}.mountPath` annotation:

1. Wait for the block device to appear in the VM (e.g., `/dev/sdX`)
2. Run `blkid` to check for existing filesystem
3. If no filesystem: format with fsType from annotation (default: ext4)
4. Create the mount point directory inside the container
5. Mount the block device at the specified path
6. The container sees a normal mounted filesystem

**Key considerations:**
- First-use formatting must be idempotent (don't reformat if filesystem exists)
- Support ext4 and xfs at minimum
- Respect read-only mount option
- Handle filesystem recovery (e.g., `fsck`) on unclean shutdown

### Component 3: StorageClass Convention

Users must create PVCs with `volumeMode: Block`. This can be enforced by:

**Option A: Separate StorageClass (recommended)**

Create a Kata-specific StorageClass that documents the requirement:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-kata
  annotations:
    description: "Ceph RBD for Kata VMs — uses volumeMode: Block for direct passthrough"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: <cluster-id>
  pool: <pool-name>
  csi.storage.k8s.io/fstype: ext4
  # Same parameters as standard ceph-rbd StorageClass
reclaimPolicy: Delete
allowVolumeExpansion: true
```

PVCs explicitly set `volumeMode: Block`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-data
spec:
  storageClassName: ceph-rbd-kata
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  resources:
    requests:
      storage: 10Gi
```

**Option B: PVC mutating webhook**

A second webhook that adds `volumeMode: Block` to PVCs based on a label (e.g., `kata-storage: "true"`). More magic, less explicit.

## Verified Test Results

Tested 2026-03-30 on MicroK8s + CRI-O 1.33.10 + MicroCeph + Kata 3.26.0 (qemu-coco-dev).

### Ceph RBD block device inside Kata VM

```
/dev/cephblock on /mnt/ceph type ext4 (rw,relatime)
```

| Aspect | Result |
|--------|--------|
| Block device visible in VM | Yes (`/dev/sda`, 64MB Ceph RBD via virtio-scsi) |
| Format inside VM | ext4, successful |
| Mount inside VM | Successful (requires `CAP_SYS_ADMIN` or privileged) |
| Data write/read | Successful |
| Host inode impact | None (filesystem owned by guest kernel) |
| Host disk impact | None (data stored in Ceph, not host filesystem) |
| CSI health checks | Unaffected (CSI manages block device, not filesystem) |

### Container rootfs (guest pull)

| Aspect | Result |
|--------|--------|
| Rootfs delivery | Guest pull (`/run/kata-containers/image/layers/`) |
| Host inode impact | None |
| Host disk impact | None |
| Host slab cache impact | None |

## Implementation Phases

### Phase 1: Manual Validation (done)

- [x] `shared_fs=none` + `force_guest_pull` for rootfs isolation
- [x] `volumeMode: Block` PVC with Ceph RBD CSI
- [x] Block device passed to Kata VM via virtio-scsi
- [x] Manual format + mount inside VM (privileged container)
- [x] Data persistence verified

### Phase 2: Agent Auto-Mount (done)

- [x] Shim patch: detect `volumeDevice` with Kata annotations, create Storage object
- [x] Agent patch: auto-format on first use (blkid + mkfs, idempotent)
- [x] Auto-mount at specified path via sandbox-level mount + OCI bind mount
- [x] Container sees a normal filesystem mount — no privileged required
- [x] Tested with PostgreSQL 16 on Ceph RBD — data persists across pod restarts

### Phase 3: Mutating Webhook (done)

- [x] PVC webhook: mutate `volumeMode: Filesystem` → `Block` for PVCs with `kata.io/block-passthrough` label
- [x] Pod webhook: translate `volumeMounts` → `volumeDevices` for block PVCs on Kata RuntimeClass pods
- [x] Add fsType and mountPath annotations automatically
- [x] Leave non-PVC mounts (ConfigMaps, Secrets, emptyDir) unchanged
- [x] Handles initContainers
- [x] Tested with standard PostgreSQL manifest — no manual volumeDevices/annotations needed
- [x] 21 unit tests (7 shim, 1 agent, 13 webhook) — all passing
- [x] BATS integration tests: 23/24 passing on k3s + CRI-O

### Phase 4: Production Hardening (next)

- [ ] Filesystem recovery (fsck on unclean shutdown)
- [ ] Volume expansion (resize block device + resize2fs inside VM)
- [ ] ReadWriteMany support assessment
- [ ] Performance benchmarking (fio: direct block vs virtio-fs)
- [ ] Multi-node testing
- [ ] Document operational procedures (backup, restore, migration)
- [ ] Upstream contribution: PR for test fixes, then block storage feature

## Open Questions

1. **ConfigMaps and Secrets:** With `shared_fs=none`, how are these delivered? They're not block devices. May need virtio-fs for these specific mount types, or a separate mechanism.

2. **emptyDir:** With `disable_guest_empty_dir=true`, emptyDir is guest-local (good for isolation). With `false`, it goes through virtio-fs. Need to decide policy.

3. **Agent vs init container:** Should the auto-mount logic live in the Kata agent (transparent to user) or in a standard init container (more portable, no agent changes)? Agent approach is cleaner but requires upstream contribution.

4. **`force_guest_pull` stability:** This feature is labeled "experimental". Need to track upstream progress toward GA.

5. **CSI drivers without `volumeMode: Block` support:** Some CSI drivers (NFS-based, hostPath) don't support block mode. These workloads can't use this approach and would need virtio-fs or a different solution.

## References

- [Block Storage Support Research](block-storage-research.md)
- [Guest Pull Isolation Report](isolation-test-report-guest-pull.md)
- [Original Isolation Report (virtio-fs)](isolation-test-report.md)
- [Kata Direct Block Device Assignment Design](../docs/design/direct-blk-device-assignment.md)
- [Kubernetes Raw Block Volume](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#raw-block-volume-support)
- [Kata CSI DirectVolume Driver](../src/tools/csi-kata-directvolume/)
