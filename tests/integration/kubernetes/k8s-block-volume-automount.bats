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
	[ "${KATA_HYPERVISOR}" == "fc" ] && skip "Firecracker does not support block auto-mount"
	[ "${KATA_HYPERVISOR}" == "stratovirt" ] && skip "StratoVirt does not support block auto-mount"
	[ "${KATA_HYPERVISOR}" == "dragonball" ] && skip "Dragonball does not support block auto-mount"

	setup_common || die "setup_common failed"

	node="$(get_one_kata_node)"
	vol_capacity="100M"
	ctr_dev_path="/dev/kata-vol-data"
	ctr_mount_path="/data"
}

create_block_pv_pvc() {
	local pv_name="$1"
	local pvc_name="$2"

	tmp_disk_image=$(exec_host "$node" mktemp --tmpdir disk.XXXXXX.img)
	exec_host "$node" truncate "$tmp_disk_image" --size "$vol_capacity"
	loop_dev=$(exec_host "$node" sudo losetup -f)
	exec_host "$node" sudo losetup "$loop_dev" "$tmp_disk_image"

	kubectl create -f volume/local-storage.yaml 2>/dev/null || true

	local node_name
	node_name="$(kubectl get node -o name | head -1)"

	tmp_pv_yaml=$(mktemp --tmpdir block_pv.XXXXX.yaml)
	sed -e "s|LOOP_DEVICE|${loop_dev}|" \
	    -e "s|HOSTNAME|${node_name##node/}|" \
	    -e "s|CAPACITY|${vol_capacity}|" \
	    -e "s|block-loop-pv|${pv_name}|" \
	    volume/block-loop-pv.yaml > "$tmp_pv_yaml"
	kubectl create -f "$tmp_pv_yaml"

	tmp_pvc_yaml=$(mktemp --tmpdir block_pvc.XXXXX.yaml)
	sed -e "s|CAPACITY|${vol_capacity}|" \
	    -e "s|block-loop-pvc|${pvc_name}|" \
	    volume/block-loop-pvc.yaml > "$tmp_pvc_yaml"
	kubectl create -f "$tmp_pvc_yaml"
}

cleanup_block_pv_pvc() {
	local pv_name="$1"
	local pvc_name="$2"

	kubectl delete pod --all --force 2>/dev/null || true
	kubectl delete pvc "$pvc_name" 2>/dev/null || true
	kubectl delete pv "$pv_name" 2>/dev/null || true
	kubectl delete storageclass local-storage 2>/dev/null || true

	if [ -n "${loop_dev:-}" ]; then
		exec_host "$node" sudo losetup -d "$loop_dev" 2>/dev/null || true
	fi
	if [ -n "${tmp_disk_image:-}" ]; then
		exec_host "$node" rm -f "$tmp_disk_image" 2>/dev/null || true
	fi
	rm -f "${tmp_pv_yaml:-}" "${tmp_pvc_yaml:-}"
}

@test "Block volume auto-mount: fresh device is formatted, mounted, and persists across restart" {
	local pv_name="block-automount-pv"
	local pvc_name="block-automount-pvc"
	local pod_name="pod-block-automount"

	create_block_pv_pvc "$pv_name" "$pvc_name"

	# Wait for PV to be available
	cmd="kubectl get pv/${pv_name} | grep Available"
	waitForProcess "$wait_time" "$sleep_time" "$cmd"

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
      claimName: ${pvc_name}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}"

	# Verify auto-mount: block device mounted as ext4 at /data
	mount_output=$(kubectl exec "$pod_name" -- mount)
	echo "$mount_output" | grep "$ctr_mount_path"

	mount_type=$(kubectl exec "$pod_name" -- sh -c "mount | grep '$ctr_mount_path' | awk '{print \$5}'")
	[ "$mount_type" = "ext4" ]

	# Verify read/write
	kubectl exec "$pod_name" -- sh -c "echo auto-mount-test > ${ctr_mount_path}/test.txt"
	result=$(kubectl exec "$pod_name" -- cat "${ctr_mount_path}/test.txt")
	[ "$result" = "auto-mount-test" ]

	# Verify it has its own inode pool (not host)
	inode_total=$(kubectl exec "$pod_name" -- sh -c "df -i ${ctr_mount_path} | tail -1 | awk '{print \$2}'")
	[ "$inode_total" -lt 100000 ]

	# --- Persistence test: delete pod, recreate, verify data ---
	kubectl delete pod "$pod_name" --wait=true

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
      claimName: ${pvc_name}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}"

	# Data should persist (agent detects existing filesystem, skips mkfs)
	result=$(kubectl exec "$pod_name" -- cat "${ctr_mount_path}/test.txt")
	[ "$result" = "auto-mount-test" ]

	cleanup_block_pv_pvc "$pv_name" "$pvc_name"
}

@test "Block volume auto-mount: no annotation means raw block passthrough" {
	local pv_name="block-raw-pv"
	local pvc_name="block-raw-pvc"
	local pod_name="pod-block-raw"

	create_block_pv_pvc "$pv_name" "$pvc_name"

	cmd="kubectl get pv/${pv_name} | grep Available"
	waitForProcess "$wait_time" "$sleep_time" "$cmd"

	# Create pod WITHOUT auto-mount annotations
	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
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
      claimName: ${pvc_name}
EOF

	kubectl wait --for=condition=ready --timeout=$timeout "pod/${pod_name}"

	# Device should exist but NOT be auto-mounted
	kubectl exec "$pod_name" -- ls -la "$ctr_dev_path"

	mount_output=$(kubectl exec "$pod_name" -- mount)
	if echo "$mount_output" | grep -q "$ctr_mount_path"; then
		fail "Expected no auto-mount without annotations"
	fi

	cleanup_block_pv_pvc "$pv_name" "$pvc_name"
}

teardown() {
	[ "${KATA_HYPERVISOR}" == "fc" ] && skip
	[ "${KATA_HYPERVISOR}" == "stratovirt" ] && skip
	[ "${KATA_HYPERVISOR}" == "dragonball" ] && skip

	kubectl describe pod 2>/dev/null || true
	teardown_common "${node}" "${node_start_time:-}"
}
