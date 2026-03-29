# Block Storage Support for Kata Containers

**Date:** 2026-03-29
**Kata Version:** 3.26.0

## Problem

Kata Containers' default rootfs delivery uses virtio-fs, which shares the host filesystem into the guest VM. This means container file operations consume host inodes, disk space, and kernel slab cache 1:1 — no disk isolation.

Block-device rootfs would give each VM its own filesystem, achieving full disk isolation.

## Architecture Overview

Three possible modes for delivering container rootfs to Kata VMs:

| Mode | Image Pull | Rootfs Delivery | Disk Isolated | Available |
|------|-----------|----------------|---------------|-----------|
| A (default) | Host | virtio-fs | No | Yes (all CRIs) |
| B (guest pull) | Guest VM | guest-local overlay | Yes | Yes (experimental) |
| C (block device) | Host | virtio-blk | Yes | Partial (containerd only) |

Mode A is the default today. Mode B is what we tested in the [guest pull isolation report](isolation-test-report-guest-pull.md). Mode C is the ideal (fast host-cached pulls + full disk isolation) but requires the CRI to produce block devices instead of overlay mounts.

## Kata Shim Block Device Support

The shim already supports block rootfs in `src/runtime-rs/crates/resource/src/rootfs/block_rootfs.rs`:

- **Real block devices** (`S_IFBLK`) — works with containerd's devmapper snapshotter
- **Block files with "loop" flag** (`S_IFREG`) — the reverted blockfile approach

The gap is not in the shim — it's in what the CRI passes to it. If the CRI gives it an overlay mount, the shim has no choice but to use virtio-fs. If the CRI gives it a block device, the shim uses virtio-blk.

## Containerd Snapshotters

### Devmapper (mature, problematic)

**Status (2026-03):** Not deprecated, still supported in containerd. Not listed in [deprecated features](https://github.com/containerd/containerd/blob/main/RELEASES.md#deprecated-features).

**Kata support:** Yes, mature, used in production (especially with Firecracker).

**Known issues:**
- Serial pod creation due to global DB lock — 100 pods = ~10s stagger ([containerd#12335](https://github.com/containerd/containerd/issues/12335))
- Unrecoverable state corruption if thin-pool is externally modified ([containerd#4790](https://github.com/containerd/containerd/issues/4790))
- Disk space not released after containers exit ([containerd#5691](https://github.com/containerd/containerd/issues/5691))
- Intermittent layer extraction failures ~1/10K pods ([containerd#8674](https://github.com/containerd/containerd/issues/8674))
- 50% slower image unpacking vs overlayfs
- Complex setup: requires pre-created thin-pool, loopback mode not for production

**Docs:** https://github.com/containerd/containerd/blob/main/docs/snapshotters/devmapper.md

### Blockfile (newer, promising, Kata support missing)

**Status (2026-03):** Added in containerd 1.7 ([PR #8511](https://github.com/containerd/containerd/pull/8511), May 2023), active development. Sparse file preservation PR from March 2026 ([PR #12956](https://github.com/containerd/containerd/pull/12956)).

**Kata support:** Not yet. Open feature request: [kata-containers#7996](https://github.com/kata-containers/kata-containers/issues/7996)

**How it works:** Creates raw block files per snapshot on the host filesystem, which can be attached to VMs via virtio-blk.

**Advantages over devmapper:**
- Simple setup (scratch directory, no thin-pool)
- Benefits from reflink/CoW filesystems (XFS, btrfs) on the host
- Sparse file support reduces disk usage

**Docs:** https://github.com/containerd/containerd/blob/main/docs/snapshotters/blockfile.md

### EROFS (read-only, already in Kata)

**Status (2026-03):** Merged in containerd 2.1 ([PR #10705](https://github.com/containerd/containerd/pull/10705)).

**Kata support:** Yes, merged ([kata-containers#11172](https://github.com/kata-containers/kata-containers/pull/11172)).

**Limitation:** Read-only filesystem — good for image layers but the writable upper layer needs a separate solution.

**Docs:** https://github.com/containerd/containerd/blob/main/docs/snapshotters/erofs.md

### Comparison

| Aspect | Devmapper | Blockfile | EROFS |
|--------|-----------|-----------|-------|
| Backend | Device-mapper thin-pool | Raw block files on host FS | Read-only FS image |
| Setup complexity | High (thin-pool required) | Low (scratch directory) | Low |
| CoW mechanism | Device-mapper snapshots | File copy (benefits from reflink) | Read-only (no CoW needed) |
| Kata support | Yes (mature) | Not yet ([#7996](https://github.com/kata-containers/kata-containers/issues/7996)) | Yes (merged) |
| Writable layer | Yes | Yes | No (needs separate solution) |
| Production maturity | Used in production | Newer, less tested | Newer |
| CRI-O support | No | No | No |

## Kata Blockfile PR (reverted)

- [PR #11466](https://github.com/kata-containers/kata-containers/pull/11466) — added blockfile-based rootfs support (commit `74eccc54e`)
- [PR #11467](https://github.com/kata-containers/kata-containers/pull/11467) — immediately reverted (commit `0c721445f`)
- Branch `revert-11466-blockfile` exists on upstream
- The approach: treat host overlay files as block files with "loop" mount option
- Likely reverted due to implementation issues with OCI layer edge cases (whiteouts, opaque directories, multi-layer stacking)

## Guest Pull (working today)

Guest pull avoids the block device problem entirely — the guest VM pulls and unpacks the container image itself, so the rootfs exists entirely inside the VM.

### CRI-O configuration

```toml
# /etc/crio/crio.conf.d/50-kata.conf
[crio.runtime.runtimes.kata-qemu-coco-dev]
  runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
  runtime_type = "vm"
  runtime_root = "/run/vc"
  privileged_without_host_devices = true
  runtime_config_path = "/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml"
  runtime_pull_image = true
```

### containerd configuration

```toml
# containerd runtime config
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu-coco-dev]
runtime_type = "io.containerd.kata-qemu-coco-dev.v2"
runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"
privileged_without_host_devices = true
pod_annotations = ["io.katacontainers.*"]
# NOTE: Do NOT set snapshotter = "nydus" unless nydus-snapshotter is installed.
# The default overlayfs snapshotter works fine with force_guest_pull.
```

### Kata config (both CRIs)

```toml
# configuration-qemu-coco-dev.toml
shared_fs = "none"
experimental_force_guest_pull = true
```

### Trade-offs
- **Latency:** Image pull happens inside VM on every pod start (~7s for busybox, ~30s for python:3-slim)
- **VM memory:** Unpacked image layers consume guest VM memory/disk
- **Maturity:** Labeled "experimental", actively tested upstream for CoCo scenarios

### Verified isolation (2026-03-29)

Tested on MicroK8s + CRI-O 1.33.10 and minikube + containerd 2.2.1:

| Resource | virtio-fs (old) | Guest pull | Result |
|----------|----------------|------------|--------|
| Inodes (10K files) | +10,002 | +0 | Isolated |
| Disk space (100MB write) | +100MB | +0 | Isolated |
| Slab cache (10K create+stat) | dentry +30K, inode +10K | ~+0 | Isolated |

Full results in [isolation-test-report-guest-pull.md](isolation-test-report-guest-pull.md).

## CRI-O Disk Isolation Options

CRI-O has no snapshotter concept (that's containerd-specific). Current options:

| Option | Works Today | Disk Isolation | Latency | Notes |
|--------|-------------|---------------|---------|-------|
| Guest pull | Yes (experimental) | Full | +7-30s/pod | Only working option for CRI-O |
| CRI-O block storage driver | No | Would be full | Minimal | Nobody is working on this |
| Shim overlay→block conversion | No | Would be full | Moderate | Reverted blockfile PR was heading here |
| Switch to containerd | Yes | Full (devmapper) | Minimal | Loses CRI-O simplicity |

## Recommendations

**For CRI-O users today:** Use guest pull. It's the only working path and upstream is actively investing in it for CoCo.

**For containerd users today:** Devmapper works but has operational pain. Wait for Kata blockfile support ([#7996](https://github.com/kata-containers/kata-containers/issues/7996)) for a simpler option.

**Best long-term bet:** Guest pull stabilizing out of experimental. Upstream CoCo investment drives this. The latency penalty may be mitigated by future image caching inside the guest.

## Key Links

- Kata blockfile feature request: https://github.com/kata-containers/kata-containers/issues/7996
- Kata EROFS integration: https://github.com/kata-containers/kata-containers/pull/11172
- Kata blockfile PR (reverted): https://github.com/kata-containers/kata-containers/pull/11466
- Containerd snapshotters overview: https://github.com/containerd/containerd/blob/main/docs/snapshotters/README.md
- Containerd deprecated features: https://github.com/containerd/containerd/blob/main/RELEASES.md#deprecated-features
- Containerd blockfile docs: https://github.com/containerd/containerd/blob/main/docs/snapshotters/blockfile.md
- Containerd devmapper docs: https://github.com/containerd/containerd/blob/main/docs/snapshotters/devmapper.md
