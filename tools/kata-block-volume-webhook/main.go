package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	// Label on PVC or StorageClass that triggers volumeMode mutation.
	labelBlockPassthrough = "kata.io/block-passthrough"

	// Annotation prefix for auto-mount instructions.
	annoPrefix = "io.katacontainers.volume"
)

// kataRuntimeClasses is the set of RuntimeClass names that trigger pod mutation.
var kataRuntimeClasses = map[string]bool{
	"kata-qemu-coco-dev":    true,
	"kata-qemu-coco-dev-rs": true,
	"kata-qemu":             true,
	"kata":                  true,
}

func main() {
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	if certFile == "" {
		certFile = "/etc/webhook/certs/tls.crt"
	}
	if keyFile == "" {
		keyFile = "/etc/webhook/certs/tls.key"
	}

	if extra := os.Getenv("KATA_RUNTIME_CLASSES"); extra != "" {
		for _, rc := range strings.Split(extra, ",") {
			kataRuntimeClasses[strings.TrimSpace(rc)] = true
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate-pvc", handleAdmission(mutatePVC))
	mux.HandleFunc("/mutate-pod", handleAdmission(mutatePod))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8443"
	}

	server := &http.Server{Addr: ":" + port, Handler: mux}

	if _, err := os.Stat(certFile); err == nil {
		cert, err := tls.LoadX509KeyPair(certFile, keyFile)
		if err != nil {
			log.Fatalf("Failed to load TLS cert: %v", err)
		}
		server.TLSConfig = &tls.Config{Certificates: []tls.Certificate{cert}}
		log.Printf("Starting webhook server on :%s (TLS)", port)
		log.Fatal(server.ListenAndServeTLS("", ""))
	} else {
		log.Printf("Starting webhook server on :%s (no TLS, dev mode)", port)
		log.Fatal(server.ListenAndServe())
	}
}

type mutateFunc func(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse

func handleAdmission(fn mutateFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}

		var review admissionv1.AdmissionReview
		if err := json.Unmarshal(body, &review); err != nil {
			http.Error(w, "decode review: "+err.Error(), http.StatusBadRequest)
			return
		}

		response := fn(review.Request)
		response.UID = review.Request.UID
		review.Response = response

		out, err := json.Marshal(review)
		if err != nil {
			http.Error(w, "encode response: "+err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	}
}

// =============================================================================
// PVC Webhook: Mutate volumeMode: Filesystem → Block
// =============================================================================

func mutatePVC(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	if req.Kind.Kind != "PersistentVolumeClaim" {
		return allowed()
	}

	var pvc corev1.PersistentVolumeClaim
	if err := json.Unmarshal(req.Object.Raw, &pvc); err != nil {
		return denied("unmarshal pvc: " + err.Error())
	}

	// Only mutate if the PVC (or its StorageClass) has the block-passthrough label
	if !hasBlockPassthroughLabel(&pvc) {
		return allowed()
	}

	// Already Block mode — nothing to do
	if pvc.Spec.VolumeMode != nil && *pvc.Spec.VolumeMode == corev1.PersistentVolumeBlock {
		return allowed()
	}

	log.Printf("PVC %s/%s: mutating volumeMode Filesystem → Block (label %s found)",
		req.Namespace, pvc.Name, labelBlockPassthrough)

	blockMode := corev1.PersistentVolumeBlock
	patches := []jsonPatch{{
		Op:    "replace",
		Path:  "/spec/volumeMode",
		Value: &blockMode,
	}}

	return patchResponse(patches)
}

func hasBlockPassthroughLabel(pvc *corev1.PersistentVolumeClaim) bool {
	// Check PVC labels
	if v, ok := pvc.Labels[labelBlockPassthrough]; ok && v == "true" {
		return true
	}

	// Check StorageClass parameters (if available)
	if pvc.Spec.StorageClassName != nil {
		config, err := rest.InClusterConfig()
		if err != nil {
			return false
		}
		clientset, err := kubernetes.NewForConfig(config)
		if err != nil {
			return false
		}
		sc, err := clientset.StorageV1().StorageClasses().Get(
			context.TODO(), *pvc.Spec.StorageClassName, metav1.GetOptions{})
		if err != nil {
			return false
		}
		if v, ok := sc.Labels[labelBlockPassthrough]; ok && v == "true" {
			return true
		}
	}
	return false
}

// =============================================================================
// Pod Webhook: Convert volumeMounts → volumeDevices + annotations
// =============================================================================

func mutatePod(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	if req.Kind.Kind != "Pod" {
		return allowed()
	}

	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		return denied("unmarshal pod: " + err.Error())
	}

	// Only process pods with a Kata RuntimeClass
	if pod.Spec.RuntimeClassName == nil || !kataRuntimeClasses[*pod.Spec.RuntimeClassName] {
		return allowed()
	}

	// Find PVC volumes that have the block-passthrough label
	blockVolumes := getBlockPassthroughVolumes(req.Namespace, &pod)
	if len(blockVolumes) == 0 {
		return allowed()
	}

	var patches []jsonPatch

	// Ensure annotations map exists
	if pod.Annotations == nil {
		patches = append(patches, jsonPatch{
			Op:    "add",
			Path:  "/metadata/annotations",
			Value: map[string]string{},
		})
	}

	// Process each container
	for ci, container := range pod.Spec.Containers {
		var keptMounts []corev1.VolumeMount
		var newDevices []corev1.VolumeDevice
		converted := false

		for _, mount := range container.VolumeMounts {
			if _, isBlock := blockVolumes[mount.Name]; !isBlock {
				keptMounts = append(keptMounts, mount)
				continue
			}

			// Convert this volumeMount to a volumeDevice
			devName := sanitizeDevName(mount.Name)
			devicePath := fmt.Sprintf("/dev/kata-vol-%s", devName)

			newDevices = append(newDevices, corev1.VolumeDevice{
				Name:       mount.Name,
				DevicePath: devicePath,
			})

			// Add auto-mount annotations.
			// Key must match what the shim extracts: device.container_path.trim("/dev/")
			annoDevName := fmt.Sprintf("kata-vol-%s", devName)
			annoMount := fmt.Sprintf("%s.%s.mount_path", annoPrefix, annoDevName)
			annoFs := fmt.Sprintf("%s.%s.fs_type", annoPrefix, annoDevName)
			patches = append(patches, jsonPatch{
				Op:    "add",
				Path:  fmt.Sprintf("/metadata/annotations/%s", escapeJSONPointer(annoMount)),
				Value: mount.MountPath,
			})
			patches = append(patches, jsonPatch{
				Op:    "add",
				Path:  fmt.Sprintf("/metadata/annotations/%s", escapeJSONPointer(annoFs)),
				Value: "ext4",
			})

			converted = true
			log.Printf("Pod %s/%s container %s: volumeMount %q (%s) → volumeDevice %s, auto-mount at %s",
				req.Namespace, pod.Name, container.Name, mount.Name, mount.MountPath, devicePath, mount.MountPath)
		}

		if !converted {
			continue
		}

		// Replace volumeMounts with only the non-block ones
		if keptMounts == nil {
			keptMounts = []corev1.VolumeMount{}
		}
		patches = append(patches, jsonPatch{
			Op:    "replace",
			Path:  fmt.Sprintf("/spec/containers/%d/volumeMounts", ci),
			Value: keptMounts,
		})

		// Add volumeDevices (ensure array exists first)
		existingDevices := container.VolumeDevices
		allDevices := append(existingDevices, newDevices...)
		if len(existingDevices) == 0 {
			patches = append(patches, jsonPatch{
				Op:    "add",
				Path:  fmt.Sprintf("/spec/containers/%d/volumeDevices", ci),
				Value: allDevices,
			})
		} else {
			patches = append(patches, jsonPatch{
				Op:    "replace",
				Path:  fmt.Sprintf("/spec/containers/%d/volumeDevices", ci),
				Value: allDevices,
			})
		}
	}

	if len(patches) == 0 {
		return allowed()
	}

	return patchResponse(patches)
}

// getBlockPassthroughVolumes returns volume names whose PVCs have the block-passthrough label.
func getBlockPassthroughVolumes(namespace string, pod *corev1.Pod) map[string]bool {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil
	}

	result := make(map[string]bool)
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim == nil {
			continue
		}
		pvc, err := clientset.CoreV1().PersistentVolumeClaims(namespace).Get(
			context.TODO(), vol.PersistentVolumeClaim.ClaimName, metav1.GetOptions{})
		if err != nil {
			continue
		}
		// Check if PVC has block-passthrough label OR is already volumeMode: Block
		hasLabel := pvc.Labels[labelBlockPassthrough] == "true"
		isBlock := pvc.Spec.VolumeMode != nil && *pvc.Spec.VolumeMode == corev1.PersistentVolumeBlock
		if hasLabel || isBlock {
			result[vol.Name] = true
		}
	}
	return result
}

// =============================================================================
// Helpers
// =============================================================================

type jsonPatch struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func allowed() *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{Allowed: true}
}

func denied(msg string) *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{
		Allowed: false,
		Result:  &metav1.Status{Message: msg},
	}
}

func patchResponse(patches []jsonPatch) *admissionv1.AdmissionResponse {
	patchBytes, err := json.Marshal(patches)
	if err != nil {
		return denied("marshal patches: " + err.Error())
	}
	patchType := admissionv1.PatchTypeJSONPatch
	return &admissionv1.AdmissionResponse{
		Allowed:   true,
		PatchType: &patchType,
		Patch:     patchBytes,
	}
}

func sanitizeDevName(name string) string {
	return strings.ReplaceAll(strings.ReplaceAll(name, ".", "-"), "_", "-")
}

func escapeJSONPointer(s string) string {
	s = strings.ReplaceAll(s, "~", "~0")
	s = strings.ReplaceAll(s, "/", "~1")
	return s
}
