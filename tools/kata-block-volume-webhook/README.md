# kata-block-volume-webhook

A Kubernetes mutating admission webhook that transforms labeled
`volumeMode: Filesystem` PVCs into block-passthrough volumes for Kata
Containers, without requiring any CSI driver changes.

Paired with the runtime-rs shim's `build_block_automount` helper and the
agent's `ensure_filesystem` helper, this provides end-to-end block volume
passthrough for stateful workloads.

Design doc: [`docs/design/block-volume-passthrough-webhook.md`](../../docs/design/block-volume-passthrough-webhook.md)
Upstream proposal: [kata-containers#12842](https://github.com/kata-containers/kata-containers/issues/12842)

## What it does

Two admission endpoints:

- **`/mutate-pvc`** — for `PersistentVolumeClaim` create:
  - Requires label `kata.io/block-passthrough: "true"` on the PVC or its
    StorageClass.
  - Rejects `ReadWriteMany` (unsafe for passthrough).
  - Rewrites `spec.volumeMode` from `Filesystem` to `Block`.

- **`/mutate-pod`** — for `Pod` create (only pods with a Kata
  `runtimeClassName`):
  - For each `volumeMounts` entry whose PVC has the
    `kata.io/block-passthrough` label:
    - Converts it to a `volumeDevices` entry at
      `/dev/kata-vol-<name>`.
    - Injects pod annotations:
      - `io.katacontainers.volume.kata-vol-<name>.mount_path`
        ← original `mountPath`
      - `io.katacontainers.volume.kata-vol-<name>.fs_type` ← `ext4`
  - Applies to both `initContainers` and `containers`.

The webhook is stateless — it only inspects the admission request plus
the referenced PVC/StorageClass. No host-side files, no persisted state.

## User experience

Users write standard Kubernetes manifests plus one label:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
  labels:
    kata.io/block-passthrough: "true"
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: ceph-rbd
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  runtimeClassName: kata-qemu-coco-dev-rs
  containers:
  - name: app
    image: postgres
    volumeMounts:
    - name: data
      mountPath: /var/lib/postgresql/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: app-data
```

The webhook handles the rest. The container sees a normal filesystem
mount at `/var/lib/postgresql/data` backed by a block device inside the
guest, with no virtio-fs involvement.

## Configuration

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `TLS_CERT_FILE` | `/etc/webhook/certs/tls.crt` | Serving certificate |
| `TLS_KEY_FILE` | `/etc/webhook/certs/tls.key` | Private key |
| `PORT` | `8443` | Listen port |
| `KATA_RUNTIME_CLASSES` | _(see main.go)_ | Comma-separated list of additional `runtimeClassName` values to treat as Kata |

If `TLS_CERT_FILE` does not exist the server runs in plaintext mode for
local development.

Built-in Kata runtime class list: `kata`, `kata-qemu`,
`kata-qemu-coco-dev`, `kata-qemu-coco-dev-rs`. Extend via
`KATA_RUNTIME_CLASSES`.

## RBAC

The webhook needs `get`/`list` on `persistentvolumeclaims` (to look up
PVC labels for referenced volumes) and `get` on `storageclasses` (for
StorageClass-level labels). See `deploy/webhook.yaml`.

## Build and deploy

```bash
# Build container image
docker build -t kata-block-volume-webhook:latest .

# Deploy to cluster (assumes TLS cert + MutatingWebhookConfiguration in place)
kubectl apply -f deploy/webhook.yaml
```

`deploy/webhook.yaml` contains a Namespace, ServiceAccount, RBAC, and
Deployment. You must supply a TLS certificate and the
`MutatingWebhookConfiguration` separately — a Helm chart with
cert-manager integration is planned as a follow-up.

## Limitations

- `ReadWriteOnce` access mode only.
- Filesystem type is hardcoded to `ext4`. Per-PVC override via label or
  annotation is a planned extension.
- Requires the runtime-rs shim (the Go shim does not implement block
  volume auto-mount).

## Testing

```bash
go test ./...
```

Unit tests cover the PVC and pod mutation logic, initContainer handling,
mixed filesystem/block PVC pods, and `ReadWriteMany` rejection.
