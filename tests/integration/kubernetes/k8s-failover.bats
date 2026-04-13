#!/usr/bin/env bats
#
# Multi-node failover tests for Kata + Ceph RBD.
# Requires: 3-node cluster (kata-master + 2 workers), ceph-rbd StorageClass.
#
# Usage:
#   KUBECONFIG=/tmp/kata-dev-kubeconfig.yaml bats k8s-failover.bats
#

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/../../common.bash"
load "${BATS_TEST_DIRNAME}/tests_common.sh"

# --- helpers ---

# Get the node a pod is running on
get_pod_node() {
    kubectl get pod "$1" -o jsonpath='{.spec.nodeName}'
}

# Wait for a pod to be running on a specific node (or any node if not specified)
wait_pod_running() {
    local pod="$1" timeout="${2:-120}"
    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        if kubectl wait --for=condition=ready "pod/$pod" --timeout=10s 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    echo "Pod $pod not ready within ${timeout}s" >&2
    kubectl describe "pod/$pod" 2>&1 | tail -15 >&2
    return 1
}

# Write a marker file to a PVC-backed path
write_marker() {
    local pod="$1" path="$2" content="$3"
    kubectl exec "$pod" -- sh -c "echo '$content' > $path"
}

# Read a marker file from a PVC-backed path
read_marker() {
    local pod="$1" path="$2"
    kubectl exec "$pod" -- cat "$path"
}

setup() {
    # Skip if not a multi-node cluster
    local node_count
    node_count=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [[ "$node_count" -lt 3 ]]; then
        skip "Requires 3+ node cluster (have $node_count)"
    fi

    # Skip if no ceph-rbd StorageClass
    if ! kubectl get sc ceph-rbd &>/dev/null; then
        skip "Requires ceph-rbd StorageClass"
    fi

    # Pre-clean from any prior failed run — each test must apply its own StatefulSet spec
    kubectl delete statefulset failover-test --ignore-not-found --timeout=30s
    kubectl delete pvc data-failover-test-0 --ignore-not-found
    kubectl delete pod failover-test-0 --force --grace-period=0 --ignore-not-found
}

teardown() {
    # On failure: leave resources intact for investigation, only restore nodes
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "# TEST FAILED — leaving resources for investigation" >&2
        echo "# To inspect: kubectl get pods,pvc,statefulset -o wide" >&2
        echo "# To clean up: kubectl delete statefulset failover-test; kubectl delete pvc data-failover-test-0" >&2
    else
        # On success: clean up
        kubectl delete statefulset failover-test --ignore-not-found --timeout=60s 2>/dev/null || true
        kubectl delete pvc data-failover-test-0 --ignore-not-found 2>/dev/null || true
        kubectl delete pod failover-test-0 --force --grace-period=0 2>/dev/null || true
    fi

    # Always ensure both workers are running (test may have stopped one)
    for w in kata-worker-1 kata-worker-2; do
        if multipass info "$w" --format csv 2>/dev/null | tail -1 | cut -d, -f2 | grep -q Stopped; then
            multipass start "$w"
            local deadline=$((SECONDS + 120))
            while [[ $SECONDS -lt $deadline ]]; do
                if kubectl get node "$w" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
                    break
                fi
                sleep 5
            done
        fi
    done

    # Clear any Ceph blocklist entries we added (otherwise the 1-hour expiry
    # blocks the worker from RBD on the next test run — "transport endpoint shutdown")
    for w in kata-worker-1 kata-worker-2; do
        local wip
        wip=$(multipass info "$w" --format csv 2>/dev/null | tail -1 | cut -d, -f3)
        if [[ -n "$wip" ]]; then
            multipass exec kata-master -- sudo ceph osd blocklist rm "${wip}:0/0" 2>/dev/null || true
        fi
    done
}

@test "Vanilla Ceph RBD: data survives node failure with kata runtime" {
    # Create StatefulSet with Ceph RBD PVC, pinned to worker-1
    kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: failover-test
spec:
  serviceName: failover-test
  replicas: 1
  selector:
    matchLabels:
      app: failover-test
  template:
    metadata:
      labels:
        app: failover-test
    spec:
      runtimeClassName: kata-qemu-coco-dev
      terminationGracePeriodSeconds: 5
      nodeSelector:
        kubernetes.io/hostname: kata-worker-1
      containers:
      - name: app
        image: busybox
        command: ["sleep", "infinity"]
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ceph-rbd
      resources:
        requests:
          storage: 64Mi
EOF

    # Wait for pod to be ready
    run wait_pod_running "failover-test-0" 120
    [ "$status" -eq 0 ]

    # Verify running on worker-1
    local node
    node=$(get_pod_node "failover-test-0")
    [ "$node" = "kata-worker-1" ]

    # Write test data
    local marker="failover-test-$(date +%s)"
    write_marker "failover-test-0" "/data/marker.txt" "$marker"

    # Flush write to the backing store before killing the node (virtio-fs → host ext4 → RBD)
    kubectl exec failover-test-0 -- sync

    # Verify data is readable
    local read_back
    read_back=$(read_marker "failover-test-0" "/data/marker.txt")
    [ "$read_back" = "$marker" ]

    # --- Simulate node failure ---
    # Capture worker-1 IP before stopping (multipass info returns no IP for stopped VMs)
    local w1ip
    w1ip=$(multipass info kata-worker-1 --format csv | tail -1 | cut -d, -f3)
    [ -n "$w1ip" ]

    # Stop worker-1 VM
    multipass stop --force kata-worker-1

    # Wait for Kubernetes to detect node as NotReady
    local deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
        local node_status
        node_status=$(kubectl get node kata-worker-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$node_status" != "True" ]]; then
            break
        fi
        sleep 5
    done

    # Remove nodeSelector so StatefulSet can schedule on worker-2
    kubectl patch statefulset failover-test --type='json' \
        -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'

    # Delete the pod to trigger reschedule (it's stuck in Terminating on a dead node)
    kubectl delete pod failover-test-0 --force --grace-period=0

    # Delete stale VolumeAttachment — RBD is RWO, the volume attachment is stuck
    # on the dead node and prevents rescheduling to another node.
    # This is standard Kubernetes behavior for node failures with RWO volumes.
    local va
    va=$(kubectl get volumeattachment -o jsonpath='{.items[?(@.spec.nodeName=="kata-worker-1")].metadata.name}')
    if [[ -n "$va" ]]; then
        kubectl delete volumeattachment "$va" --force --grace-period=0
    fi

    # Blacklist the dead node in Ceph so the RBD exclusive lock is released
    multipass exec kata-master -- sudo ceph osd blocklist add "$w1ip"

    # Wait for pod to come up on worker-2
    run wait_pod_running "failover-test-0" 600
    [ "$status" -eq 0 ]

    # Verify it moved to worker-2
    node=$(get_pod_node "failover-test-0")
    [ "$node" = "kata-worker-2" ]

    # --- Verify data survived ---
    read_back=$(read_marker "failover-test-0" "/data/marker.txt")
    [ "$read_back" = "$marker" ]
}

@test "Block passthrough: data survives node failure with kata runtime" {
    # Create StatefulSet with block volumeMode + kata annotations for direct passthrough.
    # The shim reads annotations to auto-mount block devices inside the VM.
    kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: failover-test
spec:
  serviceName: failover-test
  replicas: 1
  selector:
    matchLabels:
      app: failover-test
  template:
    metadata:
      labels:
        app: failover-test
      annotations:
        io.katacontainers.volume.block-data.mount_path: "/data"
        io.katacontainers.volume.block-data.fs_type: "ext4"
    spec:
      runtimeClassName: kata-qemu-coco-dev-runtime-rs
      terminationGracePeriodSeconds: 5
      nodeSelector:
        kubernetes.io/hostname: kata-worker-1
      containers:
      - name: app
        image: busybox
        command: ["sleep", "infinity"]
        volumeDevices:
        - name: data
          devicePath: /dev/block-data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ceph-rbd
      volumeMode: Block
      resources:
        requests:
          storage: 64Mi
EOF

    # Wait for pod to be ready
    run wait_pod_running "failover-test-0" 180
    [ "$status" -eq 0 ]

    # Verify running on worker-1
    local node
    node=$(get_pod_node "failover-test-0")
    [ "$node" = "kata-worker-1" ]

    # Verify /data is a real block device mount (not tmpfs)
    local mount_type
    mount_type=$(kubectl exec failover-test-0 -- sh -c "df -T /data | tail -1 | awk '{print \$2}'" 2>&1)
    echo "mount type: $mount_type"
    [ "$mount_type" = "ext4" ]

    # Write test data
    local marker="block-failover-$(date +%s)"
    write_marker "failover-test-0" "/data/marker.txt" "$marker"

    # Sync to ensure data is flushed to block device
    kubectl exec failover-test-0 -- sync

    # Verify data is readable
    local read_back
    read_back=$(read_marker "failover-test-0" "/data/marker.txt")
    [ "$read_back" = "$marker" ]

    # --- Simulate node failure ---
    # Capture worker-1 IP before stopping (stopped VMs have no IP in multipass info)
    local worker1_ip
    worker1_ip=$(multipass info kata-worker-1 --format csv | tail -1 | cut -d, -f3)
    [ -n "$worker1_ip" ]

    multipass stop --force kata-worker-1

    # Wait for Kubernetes to detect node as NotReady
    local deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
        local node_status
        node_status=$(kubectl get node kata-worker-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$node_status" != "True" ]]; then
            break
        fi
        sleep 5
    done

    # Remove nodeSelector so StatefulSet can schedule on worker-2
    kubectl patch statefulset failover-test --type='json' \
        -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'

    # Delete the pod (stuck Terminating on dead node)
    kubectl delete pod failover-test-0 --force --grace-period=0

    # Delete stale VolumeAttachment for RWO reattach
    local va
    va=$(kubectl get volumeattachment -o jsonpath='{.items[?(@.spec.nodeName=="kata-worker-1")].metadata.name}')
    if [[ -n "$va" ]]; then
        kubectl delete volumeattachment "$va" --force --grace-period=0
    fi

    # Blacklist the dead node in Ceph so the RBD exclusive lock is released immediately
    multipass exec kata-master -- sudo ceph osd blocklist add "$worker1_ip"

    # Wait for pod to come up on worker-2 (allow extra time for RBD reattach)
    run wait_pod_running "failover-test-0" 600
    [ "$status" -eq 0 ]

    # Verify it moved to worker-2
    node=$(get_pod_node "failover-test-0")
    [ "$node" = "kata-worker-2" ]

    # Verify mount is still ext4 (not tmpfs)
    mount_type=$(kubectl exec failover-test-0 -- sh -c "df -T /data | tail -1 | awk '{print \$2}'" 2>&1)
    [ "$mount_type" = "ext4" ]

    # --- Verify data survived ---
    read_back=$(read_marker "failover-test-0" "/data/marker.txt")
    [ "$read_back" = "$marker" ]
}
