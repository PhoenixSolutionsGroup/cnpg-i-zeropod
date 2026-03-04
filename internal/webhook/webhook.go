// Package webhook implements a MutatingAdmissionWebhook that injects zeropod
// configuration into CNPG Pooler (PgBouncer) pods. CNPG-I lifecycle hooks only
// intercept instance pods; Pooler pods are created via a Deployment and bypass
// the plugin system.
package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"

	cnpgv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/machinery/pkg/log"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	admissionv1 "k8s.io/api/admission/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

const (
	annotationScaleToZeroEnabled = "cnpg.io/scale-to-zero-enabled"
	annotationInactivitySeconds  = "cnpg.io/scale-to-zero-inactivity-seconds"
	defaultScaledownDuration     = "300s"

	zeropodPortsMap          = "zeropod.ctrox.dev/ports-map"
	zeropodContainerNames    = "zeropod.ctrox.dev/container-names"
	zeropodScaledownDuration = "zeropod.ctrox.dev/scaledown-duration"
	zeropodCPURequests       = "zeropod.ctrox.dev/cpu-requests"
	zeropodMemoryRequests    = "zeropod.ctrox.dev/memory-requests"
	zeropodWakePeers         = "zeropod.ctrox.dev/wake-peers"

	zeropodRuntimeClass = "zeropod"
)

// Handler mutates Pooler pods to inject zeropod configuration.
type Handler struct {
	Client  client.Client
	Decoder admission.Decoder
}

// Handle implements admission.Handler.
func (h *Handler) Handle(ctx context.Context, req admission.Request) admission.Response {
	logger := log.FromContext(ctx).WithName("cnpg_i_zeropod_webhook")

	pod := &corev1.Pod{}
	if err := h.Decoder.Decode(req, pod); err != nil {
		return admission.Errored(http.StatusBadRequest, fmt.Errorf("decoding pod: %w", err))
	}

	// Only handle pooler pods.
	if pod.Labels["cnpg.io/podRole"] != "pooler" {
		return admission.Allowed("not a pooler pod")
	}

	clusterName := pod.Labels["cnpg.io/cluster"]
	if clusterName == "" {
		return admission.Allowed("no cluster label")
	}

	// Look up the CNPG Cluster to check annotations.
	namespace := req.Namespace
	if namespace == "" {
		namespace = pod.Namespace
	}

	cluster := &cnpgv1.Cluster{}
	if err := h.Client.Get(ctx, types.NamespacedName{
		Name:      clusterName,
		Namespace: namespace,
	}, cluster); err != nil {
		logger.Error(err, "failed to get cluster", "cluster", clusterName)
		return admission.Allowed("cluster lookup failed, skipping")
	}

	if cluster.Annotations[annotationScaleToZeroEnabled] != "true" {
		return admission.Allowed("scale-to-zero not enabled")
	}

	// Determine scaledown duration.
	scaledownDuration := defaultScaledownDuration
	if seconds, ok := cluster.Annotations[annotationInactivitySeconds]; ok {
		if s, err := strconv.Atoi(seconds); err == nil && s > 0 {
			scaledownDuration = fmt.Sprintf("%ds", s)
		}
	}

	// Look up the -rw service ClusterIP for wake-peers. The zeropod shim runs
	// on the host and cannot resolve cluster DNS names, so we inject the IP.
	var wakePeersValue string
	rwSvc := &corev1.Service{}
	if err := h.Client.Get(ctx, types.NamespacedName{
		Name:      clusterName + "-rw",
		Namespace: namespace,
	}, rwSvc); err == nil && rwSvc.Spec.ClusterIP != "" {
		wakePeersValue = fmt.Sprintf("%s:5432", rwSvc.Spec.ClusterIP)
	} else {
		logger.Info("could not resolve -rw service ClusterIP for wake-peers", "error", err)
	}

	// Build JSON patch.
	var patches []map[string]interface{}

	// Set runtimeClassName.
	patches = append(patches, map[string]interface{}{
		"op":    "add",
		"path":  "/spec/runtimeClassName",
		"value": zeropodRuntimeClass,
	})

	// Ensure annotations map exists.
	if pod.Annotations == nil {
		patches = append(patches, map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations",
			"value": map[string]string{},
		})
	}

	// Add zeropod annotations.
	patches = append(patches,
		map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodPortsMap),
			"value": "pgbouncer=5432",
		},
		map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodContainerNames),
			"value": "pgbouncer",
		},
		map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodScaledownDuration),
			"value": scaledownDuration,
		},
		map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodCPURequests),
			"value": `{"pgbouncer":"0"}`,
		},
		map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodMemoryRequests),
			"value": `{"pgbouncer":"0"}`,
		},
	)

	// Wake the PG instance concurrently when PgBouncer is restored.
	if wakePeersValue != "" {
		patches = append(patches, map[string]interface{}{
			"op":    "add",
			"path":  "/metadata/annotations/" + escapeJSONPointer(zeropodWakePeers),
			"value": wakePeersValue,
		})
	}

	// Remove liveness probe on the pgbouncer container.
	for i, c := range pod.Spec.Containers {
		if c.Name == "pgbouncer" {
			if c.LivenessProbe != nil {
				patches = append(patches, map[string]interface{}{
					"op":   "remove",
					"path": fmt.Sprintf("/spec/containers/%d/livenessProbe", i),
				})
			}
			break
		}
	}

	logger.Info("injecting zeropod into pooler pod",
		"cluster", clusterName,
		"scaledownDuration", scaledownDuration)

	patchBytes, err := json.Marshal(patches)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, fmt.Errorf("marshaling patch: %w", err))
	}

	patchType := admissionv1.PatchTypeJSONPatch
	return admission.Response{
		AdmissionResponse: admissionv1.AdmissionResponse{
			Allowed:   true,
			PatchType: &patchType,
			Patch:     patchBytes,
		},
	}
}

// escapeJSONPointer escapes '/' and '~' per RFC 6901.
func escapeJSONPointer(s string) string {
	var result []byte
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '~':
			result = append(result, '~', '0')
		case '/':
			result = append(result, '~', '1')
		default:
			result = append(result, s[i])
		}
	}
	return string(result)
}
