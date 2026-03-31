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

// kataRuntimeClasses is the set of RuntimeClass names that trigger the webhook.
var kataRuntimeClasses = map[string]bool{
	"kata-qemu-coco-dev": true,
	"kata-qemu":          true,
	"kata":               true,
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

	// Allow configuring additional RuntimeClass names
	if extra := os.Getenv("KATA_RUNTIME_CLASSES"); extra != "" {
		for _, rc := range strings.Split(extra, ",") {
			kataRuntimeClasses[strings.TrimSpace(rc)] = true
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handleMutate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8443"
	}

	server := &http.Server{
		Addr:    ":" + port,
		Handler: mux,
	}

	// Load TLS certs
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

func handleMutate(w http.ResponseWriter, r *http.Request) {
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

	response := mutate(review.Request)

	review.Response = response
	review.Response.UID = review.Request.UID

	out, err := json.Marshal(review)
	if err != nil {
		http.Error(w, "encode response: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(out)
}

func mutate(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
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

	// Find PVCs with volumeMode: Block
	blockPVCs, err := getBlockPVCs(req.Namespace, &pod)
	if err != nil {
		log.Printf("Warning: failed to check PVCs: %v", err)
		return allowed()
	}

	if len(blockPVCs) == 0 {
		return allowed()
	}

	var patches []jsonPatch

	// Process each container
	for ci, container := range pod.Spec.Containers {
		var remainingMounts []int
		for mi, mount := range container.VolumeMounts {
			volumeName := mount.Name
			if _, isBlock := blockPVCs[volumeName]; !isBlock {
				remainingMounts = append(remainingMounts, mi)
				continue
			}

			// Convert this volumeMount to a volumeDevice
			devName := sanitizeDevName(volumeName)
			devicePath := fmt.Sprintf("/dev/kata-vol-%s", devName)

			// Add volumeDevice entry
			patches = append(patches, jsonPatch{
				Op:   "add",
				Path: fmt.Sprintf("/spec/containers/%d/volumeDevices/-", ci),
				Value: corev1.VolumeDevice{
					Name:       volumeName,
					DevicePath: devicePath,
				},
			})

			// Add annotations for Kata agent auto-mount
			annoKey := fmt.Sprintf("io.katacontainers.volume.%s.mount_path", devName)
			annoFsKey := fmt.Sprintf("io.katacontainers.volume.%s.fs_type", devName)
			patches = append(patches, jsonPatch{
				Op:    "add",
				Path:  fmt.Sprintf("/metadata/annotations/%s", escapeJSONPointer(annoKey)),
				Value: mount.MountPath,
			})
			patches = append(patches, jsonPatch{
				Op:    "add",
				Path:  fmt.Sprintf("/metadata/annotations/%s", escapeJSONPointer(annoFsKey)),
				Value: "ext4",
			})

			log.Printf("Pod %s/%s: converting volumeMount %q (%s) -> volumeDevice %s, auto-mount at %s",
				req.Namespace, pod.Name, volumeName, mount.MountPath, devicePath, mount.MountPath)
		}

		// Remove converted volumeMounts (reverse order to preserve indices)
		if len(remainingMounts) < len(container.VolumeMounts) {
			// Ensure volumeDevices array exists
			if len(container.VolumeDevices) == 0 {
				patches = append([]jsonPatch{{
					Op:    "add",
					Path:  fmt.Sprintf("/spec/containers/%d/volumeDevices", ci),
					Value: []corev1.VolumeDevice{},
				}}, patches...)
			}

			// Replace volumeMounts with only the non-block ones
			var kept []corev1.VolumeMount
			for _, mi := range remainingMounts {
				kept = append(kept, container.VolumeMounts[mi])
			}
			patches = append(patches, jsonPatch{
				Op:    "replace",
				Path:  fmt.Sprintf("/spec/containers/%d/volumeMounts", ci),
				Value: kept,
			})
		}
	}

	// Ensure annotations map exists
	if pod.Annotations == nil && len(patches) > 0 {
		patches = append([]jsonPatch{{
			Op:    "add",
			Path:  "/metadata/annotations",
			Value: map[string]string{},
		}}, patches...)
	}

	if len(patches) == 0 {
		return allowed()
	}

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

// getBlockPVCs returns a map of volume names that reference block-mode PVCs.
func getBlockPVCs(namespace string, pod *corev1.Pod) (map[string]bool, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("create clientset: %w", err)
	}

	result := make(map[string]bool)
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim == nil {
			continue
		}
		pvc, err := clientset.CoreV1().PersistentVolumeClaims(namespace).Get(
			context.TODO(), vol.PersistentVolumeClaim.ClaimName, metav1.GetOptions{})
		if err != nil {
			log.Printf("Warning: failed to get PVC %s/%s: %v", namespace, vol.PersistentVolumeClaim.ClaimName, err)
			continue
		}
		if pvc.Spec.VolumeMode != nil && *pvc.Spec.VolumeMode == corev1.PersistentVolumeBlock {
			result[vol.Name] = true
		}
	}
	return result, nil
}

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

func sanitizeDevName(name string) string {
	return strings.ReplaceAll(strings.ReplaceAll(name, ".", "-"), "_", "-")
}

func escapeJSONPointer(s string) string {
	s = strings.ReplaceAll(s, "~", "~0")
	s = strings.ReplaceAll(s, "/", "~1")
	return s
}
