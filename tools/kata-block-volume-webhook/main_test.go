package main

import (
	"encoding/json"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func TestMutatePVC_WithLabel(t *testing.T) {
	pvc := corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pvc",
			Namespace: "default",
			Labels: map[string]string{
				"kata.io/block-passthrough": "true",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{},
	}

	raw, _ := json.Marshal(pvc)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "PersistentVolumeClaim"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePVC(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch == nil {
		t.Fatal("expected patch for PVC with block-passthrough label")
	}

	var patches []jsonPatch
	json.Unmarshal(resp.Patch, &patches)

	found := false
	for _, p := range patches {
		if p.Path == "/spec/volumeMode" {
			found = true
		}
	}
	if !found {
		t.Error("expected volumeMode patch")
	}
}

func TestMutatePVC_WithoutLabel(t *testing.T) {
	pvc := corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pvc",
			Namespace: "default",
		},
		Spec: corev1.PersistentVolumeClaimSpec{},
	}

	raw, _ := json.Marshal(pvc)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "PersistentVolumeClaim"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePVC(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for PVC without label")
	}
}

func TestMutatePVC_AlreadyBlock(t *testing.T) {
	blockMode := corev1.PersistentVolumeBlock
	pvc := corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pvc",
			Namespace: "default",
			Labels: map[string]string{
				"kata.io/block-passthrough": "true",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			VolumeMode: &blockMode,
		},
	}

	raw, _ := json.Marshal(pvc)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "PersistentVolumeClaim"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePVC(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for already-Block PVC")
	}
}

func TestMutatePod_KataWithVolumeMounts(t *testing.T) {
	runtimeClass := "kata-qemu-coco-dev-rs"
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			RuntimeClassName: &runtimeClass,
			Containers: []corev1.Container{
				{
					Name: "app",
					VolumeMounts: []corev1.VolumeMount{
						{Name: "data", MountPath: "/data"},
						{Name: "config", MountPath: "/etc/config"},
					},
				},
			},
			Volumes: []corev1.Volume{
				{
					Name: "data",
					VolumeSource: corev1.VolumeSource{
						PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
							ClaimName: "my-pvc",
						},
					},
				},
				{
					Name: "config",
					VolumeSource: corev1.VolumeSource{
						ConfigMap: &corev1.ConfigMapVolumeSource{
							LocalObjectReference: corev1.LocalObjectReference{Name: "my-config"},
						},
					},
				},
			},
		},
	}

	raw, _ := json.Marshal(pod)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "Pod"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	// Note: mutatePod calls getBlockPassthroughVolumes which requires in-cluster config.
	// In unit tests, this will fail gracefully (returns nil) so no PVCs will be found.
	// This tests the non-Kata and no-PVC code paths.
	resp := mutatePod(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	// No patches because getBlockPassthroughVolumes returns nil outside cluster
	if resp.Patch != nil {
		t.Error("expected no patch when PVC lookup unavailable")
	}
}

func TestMutatePod_NonKataRuntime(t *testing.T) {
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "runc-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "app"},
			},
		},
	}

	raw, _ := json.Marshal(pod)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "Pod"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePod(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for non-Kata pod")
	}
}

func TestSanitizeDevName(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"pgdata", "pgdata"},
		{"my.volume", "my-volume"},
		{"my_volume", "my-volume"},
		{"my.complex_name", "my-complex-name"},
	}

	for _, tt := range tests {
		got := sanitizeDevName(tt.input)
		if got != tt.expected {
			t.Errorf("sanitizeDevName(%q) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}

func TestMutatePVC_LabelValueNotTrue(t *testing.T) {
	pvc := corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pvc",
			Namespace: "default",
			Labels: map[string]string{
				"kata.io/block-passthrough": "false",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{},
	}

	raw, _ := json.Marshal(pvc)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "PersistentVolumeClaim"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePVC(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch != nil {
		t.Error("expected no patch when label value is 'false'")
	}
}

func TestMutatePVC_WrongResource(t *testing.T) {
	resp := mutatePVC(&admissionv1.AdmissionRequest{
		Kind: metav1.GroupVersionKind{Kind: "Pod"},
	})
	if !resp.Allowed {
		t.Fatal("expected allowed for non-PVC resource")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for non-PVC resource")
	}
}

func TestMutatePod_WithInitContainers(t *testing.T) {
	// InitContainers with volumeMounts should also be considered
	// but our webhook currently only processes spec.containers.
	// This test documents the current behavior.
	runtimeClass := "kata-qemu-coco-dev-rs"
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pod-with-init",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			RuntimeClassName: &runtimeClass,
			InitContainers: []corev1.Container{
				{
					Name: "init",
					VolumeMounts: []corev1.VolumeMount{
						{Name: "data", MountPath: "/data"},
					},
				},
			},
			Containers: []corev1.Container{
				{Name: "app"},
			},
		},
	}

	raw, _ := json.Marshal(pod)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "Pod"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePod(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	// Current behavior: initContainers are not processed (getBlockPassthroughVolumes
	// returns nil outside cluster). This is a known limitation to address later.
}

func TestMutatePod_NoVolumes(t *testing.T) {
	runtimeClass := "kata"
	pod := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "no-vol-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			RuntimeClassName: &runtimeClass,
			Containers: []corev1.Container{
				{Name: "app"},
			},
		},
	}

	raw, _ := json.Marshal(pod)
	req := &admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Kind: "Pod"},
		Namespace: "default",
		Object:    runtime.RawExtension{Raw: raw},
	}

	resp := mutatePod(req)
	if !resp.Allowed {
		t.Fatal("expected allowed")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for pod without volumes")
	}
}

func TestMutatePod_WrongResource(t *testing.T) {
	resp := mutatePod(&admissionv1.AdmissionRequest{
		Kind: metav1.GroupVersionKind{Kind: "PersistentVolumeClaim"},
	})
	if !resp.Allowed {
		t.Fatal("expected allowed for non-Pod resource")
	}
	if resp.Patch != nil {
		t.Error("expected no patch for non-Pod resource")
	}
}

func TestEscapeJSONPointer(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"simple", "simple"},
		{"io.katacontainers.volume.data.mount_path", "io.katacontainers.volume.data.mount_path"},
		{"path/with/slashes", "path~1with~1slashes"},
		{"tilde~here", "tilde~0here"},
	}

	for _, tt := range tests {
		got := escapeJSONPointer(tt.input)
		if got != tt.expected {
			t.Errorf("escapeJSONPointer(%q) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}
