#!/usr/bin/env bats
#
# Copyright (c) 2026
#
# SPDX-License-Identifier: Apache-2.0
#
# Test: Block volume auto-mount via Kata annotations.
#
# When a pod has volumeDevices with io.katacontainers.volume.<dev>.mount_path
# and fs_type annotations, the Kata agent should automatically format (if
# needed) and mount the block device inside the container as a regular
# filesystem mount. No privileged containers required.

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/../../common.bash"
load "${BATS_TEST_DIRNAME}/tests_common.sh"

setup() {
	setup_common || die "setup_common failed"

	node="$(get_one_kata_node)"
	pod_name="pod-block-automount"
	volume_name="block-automount-pv"
	volume_claim="block-automount-pvc"
	vol_capacity="100M"
	ctr_dev_path="/dev/kata-vol-data"
	ctr_mount_path="/data"

	# Create loop device for block storage
	tmp_disk_image=$(exec_host "$node" mktemp --tmpdir disk.XXXXXX.img)
	exec_host "$node" truncate "$tmp_disk_image" --size "$vol_capacity"
	loop_dev=$(exec_host "$node" sudo losetup -f)
	exec_host "$node" sudo losetup "$loop_dev" "$tmp_disk_image"
}

@test "Block volume auto-mount: fresh device is formatted and mounted" {
	# Create storage class and PV/PVC
	kubectl create -f volume/local-storage.yaml

	tmp_pv_yaml=$(mktemp --tmpdir block_pv.XXXXX.yaml)
	sed -e "s|LOOP_DEVICE|${loop_dev}|" volume/block-loop-pv.yaml > "$tmp_pv_yaml"
	node_name="$(kubectl get node -o name)"
	sed -i "s|HOSTNAME|${node_name##node/}|" "$tmp_pv_yaml"
	sed -i "s|CAPACITY|${vol_capacity}|" "$tmp_pv_yaml"
	sed -i "s|block-loop-pv|${volume_name}|" "$tmp_pv_yaml"
	kubectl create -f "$tmp_pv_yaml"
	cmd="kubectl get pv/${volume_name} | grep Available"
	waitForProcess "$wait_time" "$sleep_time" "$cmd"

	tmp_pvc_yaml=$(mktemp --tmpdir block_pvc.XXXXX.yaml)
	sed -e "s|CAPACITY|${vol_capacity}|" volume/block-loop-pvc.yaml > "$tmp_pvc_yaml"
	sed -i "s|block-loop-pvc|${volume_claim}|" "$tmp_pvc_yaml"
	kubectl create -f "$tmp_pvc_yaml"

	# Create pod with auto-mount annotations
	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  annotations:
    io.katacontainers.volume.kata-vol-data.mount_path: "${ctr_mount_path}"
    io.katacontainers.volume.kata-vol-data.fs_type: "ext4"
spec:
  runtimeClassName: kata
  containers:
  - name: app
    image: quay.io/prometheus/busybox:latest
    command: ["sleep", "infinity"]
    volumeDevices:
    - name: data
      devicePath: ${ctr_dev_path}
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${volume_claim}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}"

	# Verify the block device is mounted as a filesystem at the requested path
	mount_output=$(kubectl exec "$pod_name" -- mount)
	echo "$mount_output" | grep "$ctr_mount_path"

	# Verify it's a real filesystem (ext4), not tmpfs
	mount_type=$(kubectl exec "$pod_name" -- sh -c "mount | grep '$ctr_mount_path' | awk '{print \$5}'")
	[ "$mount_type" = "ext4" ]

	# Verify read/write works
	kubectl exec "$pod_name" -- sh -c "echo auto-mount-test > ${ctr_mount_path}/test.txt"
	result=$(kubectl exec "$pod_name" -- cat "${ctr_mount_path}/test.txt")
	[ "$result" = "auto-mount-test" ]

	# Verify it has its own inode pool (not host filesystem)
	inode_total=$(kubectl exec "$pod_name" -- sh -c "df -i ${ctr_mount_path} | tail -1 | awk '{print \$2}'")
	[ "$inode_total" -lt 100000 ] # Block device has small inode count, not host's millions
}

@test "Block volume auto-mount: data persists across pod restart" {
	# Write data in first pod
	kubectl exec "$pod_name" -- sh -c "echo persistent-data > ${ctr_mount_path}/persist.txt"

	# Delete pod
	kubectl delete pod "$pod_name" --wait=true

	# Recreate pod with same PVC
	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  annotations:
    io.katacontainers.volume.kata-vol-data.mount_path: "${ctr_mount_path}"
    io.katacontainers.volume.kata-vol-data.fs_type: "ext4"
spec:
  runtimeClassName: kata
  containers:
  - name: app
    image: quay.io/prometheus/busybox:latest
    command: ["sleep", "infinity"]
    volumeDevices:
    - name: data
      devicePath: ${ctr_dev_path}
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${volume_claim}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}"

	# Verify data persisted — agent should NOT reformat (blkid detects existing fs)
	result=$(kubectl exec "$pod_name" -- cat "${ctr_mount_path}/persist.txt")
	[ "$result" = "persistent-data" ]
}

@test "Block volume auto-mount: no annotation means raw block passthrough" {
	# Delete the annotated pod
	kubectl delete pod "$pod_name" --wait=true

	# Create pod WITHOUT auto-mount annotations — should get raw block device
	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}-raw
spec:
  runtimeClassName: kata
  containers:
  - name: app
    image: quay.io/prometheus/busybox:latest
    command: ["sleep", "infinity"]
    volumeDevices:
    - name: data
      devicePath: ${ctr_dev_path}
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${volume_claim}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}-raw"

	# The device should exist but NOT be auto-mounted
	kubectl exec "${pod_name}-raw" -- ls -la "$ctr_dev_path"

	# No mount at /data
	mount_output=$(kubectl exec "${pod_name}-raw" -- mount)
	if echo "$mount_output" | grep -q "$ctr_mount_path"; then
		fail "Expected no auto-mount without annotations, but found mount at $ctr_mount_path"
	fi

	kubectl delete pod "${pod_name}-raw" --wait=true
}

teardown() {
	# Debugging information
	kubectl describe "pod/$pod_name" 2>/dev/null || true

	# Delete k8s resources
	kubectl delete pod "$pod_name" 2>/dev/null || true
	kubectl delete pod "${pod_name}-raw" 2>/dev/null || true
	kubectl delete pvc "$volume_claim" 2>/dev/null || true
	kubectl delete pv "$volume_name" 2>/dev/null || true
	kubectl delete storageclass local-storage 2>/dev/null || true

	# Delete temporary yaml files
	rm -f "$tmp_pv_yaml" "$tmp_pvc_yaml"

	# Remove loop device
	exec_host "$node" sudo losetup -d "$loop_dev" 2>/dev/null || true
	exec_host "$node" rm -f "$tmp_disk_image" 2>/dev/null || true

	teardown_common "${node}" "${node_start_time:-}"
}
