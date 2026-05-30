// Package lifecycle implements the CNPG-I lifecycle hooks for zeropod injection.
package lifecycle

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/decoder"
	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/object"
	"github.com/cloudnative-pg/cnpg-i/pkg/lifecycle"
	"github.com/cloudnative-pg/machinery/pkg/log"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

const (
	// Cluster annotations we read.
	annotationScaleToZeroEnabled     = "cnpg.io/scale-to-zero-enabled"
	annotationInactivitySeconds      = "cnpg.io/scale-to-zero-inactivity-seconds"
	annotationRestoreTimeout         = "cnpg.io/scale-to-zero-restore-timeout"
	defaultScaledownDuration         = "300s"

	// Zeropod annotations we inject.
	zeropodPortsMap          = "zeropod.ctrox.dev/ports-map"
	zeropodContainerNames    = "zeropod.ctrox.dev/container-names"
	zeropodScaledownDuration = "zeropod.ctrox.dev/scaledown-duration"
	zeropodCPURequests       = "zeropod.ctrox.dev/cpu-requests"
	zeropodMemoryRequests    = "zeropod.ctrox.dev/memory-requests"
	zeropodRestoreTimeout    = "zeropod.ctrox.dev/restore-timeout"
	zeropodProxyTimeout      = "zeropod.ctrox.dev/proxy-timeout"
	zeropodConnectTimeout    = "zeropod.ctrox.dev/connect-timeout"

	// The RuntimeClass to inject.
	zeropodRuntimeClass = "zeropod"
)

// Implementation is the lifecycle hook implementation.
type Implementation struct {
	lifecycle.UnimplementedOperatorLifecycleServer
}

// GetCapabilities declares that we intercept Pod CREATE operations.
func (Implementation) GetCapabilities(
	_ context.Context,
	_ *lifecycle.OperatorLifecycleCapabilitiesRequest,
) (*lifecycle.OperatorLifecycleCapabilitiesResponse, error) {
	return &lifecycle.OperatorLifecycleCapabilitiesResponse{
		LifecycleCapabilities: []*lifecycle.OperatorLifecycleCapabilities{
			{
				Group: "",
				Kind:  "Pod",
				OperationTypes: []*lifecycle.OperatorOperationType{
					{Type: lifecycle.OperatorOperationType_TYPE_CREATE},
				},
			},
		},
	}, nil
}

// LifecycleHook is called by the CNPG operator when creating pods.
// It injects the zeropod runtime class and annotations if scale-to-zero
// is enabled on the cluster.
func (impl Implementation) LifecycleHook(
	ctx context.Context,
	request *lifecycle.OperatorLifecycleRequest,
) (*lifecycle.OperatorLifecycleResponse, error) {
	logger := log.FromContext(ctx).WithName("cnpg_i_zeropod_lifecycle")

	kind, err := object.GetKind(request.GetObjectDefinition())
	if err != nil {
		return nil, fmt.Errorf("getting object kind: %w", err)
	}

	if kind != "Pod" {
		return &lifecycle.OperatorLifecycleResponse{}, nil
	}

	// Decode the cluster to check annotations.
	cluster, err := decoder.DecodeClusterLenient(request.GetClusterDefinition())
	if err != nil {
		return nil, fmt.Errorf("decoding cluster: %w", err)
	}

	// Check if scale-to-zero is enabled on the cluster.
	if cluster.Annotations[annotationScaleToZeroEnabled] != "true" {
		logger.Debug("scale-to-zero not enabled, skipping",
			"cluster", cluster.Name)
		return &lifecycle.OperatorLifecycleResponse{}, nil
	}

	// Determine the scaledown duration.
	scaledownDuration := defaultScaledownDuration
	if seconds, ok := cluster.Annotations[annotationInactivitySeconds]; ok {
		if s, err := strconv.Atoi(seconds); err == nil && s > 0 {
			scaledownDuration = fmt.Sprintf("%ds", s)
		}
	}

	// Decode the pod so we can produce a proper diff-based patch.
	pod, err := decoder.DecodePodJSON(request.GetObjectDefinition())
	if err != nil {
		return nil, fmt.Errorf("decoding pod: %w", err)
	}

	mutatedPod := pod.DeepCopy()

	// Determine the target container based on pod role.
	containerName := "postgres"
	if mutatedPod.Labels["cnpg.io/podRole"] == "pooler" {
		containerName = "pgbouncer"
	}

	// Set the RuntimeClass.
	runtimeClass := zeropodRuntimeClass
	mutatedPod.Spec.RuntimeClassName = &runtimeClass

	// Set zeropod annotations.
	if mutatedPod.Annotations == nil {
		mutatedPod.Annotations = make(map[string]string)
	}
	mutatedPod.Annotations[zeropodPortsMap] = fmt.Sprintf("%s=5432", containerName)
	mutatedPod.Annotations[zeropodContainerNames] = containerName
	mutatedPod.Annotations[zeropodScaledownDuration] = scaledownDuration
	mutatedPod.Annotations[zeropodCPURequests] = fmt.Sprintf(`{"%s":"0"}`, containerName)
	mutatedPod.Annotations[zeropodMemoryRequests] = fmt.Sprintf(`{"%s":"0"}`, containerName)
	if restoreTimeout, ok := cluster.Annotations[annotationRestoreTimeout]; ok {
		mutatedPod.Annotations[zeropodRestoreTimeout] = restoreTimeout
	}
	// Set generous proxy/connect timeouts so the activator doesn't drop
	// connections while CRIU restore is in progress under load.
	mutatedPod.Annotations[zeropodProxyTimeout] = "30s"
	mutatedPod.Annotations[zeropodConnectTimeout] = "30s"

	// Zero out resource requests on all init containers so the scheduler
	// doesn't count them against node capacity. Limits are preserved.
	zero := resource.MustParse("0")
	for i := range mutatedPod.Spec.InitContainers {
		c := &mutatedPod.Spec.InitContainers[i]
		if c.Resources.Requests == nil {
			c.Resources.Requests = corev1.ResourceList{}
		}
		c.Resources.Requests[corev1.ResourceCPU] = zero
		c.Resources.Requests[corev1.ResourceMemory] = zero
	}

	// Find the target container and apply CRIU compatibility patches.
	targetIdx := -1
	for i := range mutatedPod.Spec.Containers {
		if mutatedPod.Spec.Containers[i].Name != containerName {
			continue
		}
		targetIdx = i

		// Zero out resource requests on the target container so the
		// scheduler doesn't count them against node capacity.
		c := &mutatedPod.Spec.Containers[i]
		if c.Resources.Requests == nil {
			c.Resources.Requests = corev1.ResourceList{}
		}
		c.Resources.Requests[corev1.ResourceCPU] = zero
		c.Resources.Requests[corev1.ResourceMemory] = zero

		// GODEBUG flags only needed for the Go-based CNPG instance manager,
		// not for PgBouncer (C process).
		if containerName == "postgres" {
			c.Env = append(c.Env, corev1.EnvVar{
				Name:  "GODEBUG",
				Value: "multipathtcp=0,pidfd=0",
			})
		}

		break
	}

	// Generate the diff-based JSON patch.
	patch, err := object.CreatePatch(mutatedPod, pod)
	if err != nil {
		return nil, fmt.Errorf("creating patch: %w", err)
	}

	// Remove all probes. CNPG adds probes AFTER calling the lifecycle
	// hook, so the pod we receive has no probes. We append RFC 6902
	// "remove" ops targeting the final pod's probes.
	// All probe types are incompatible with zeropod scale-to-zero:
	//   - startupProbe (HTTPS:8000): TLS SNI mismatch on pod IP, pod never Ready
	//   - readinessProbe (TCP:5432): resets eBPF idle timer, prevents scale-down
	//   - livenessProbe (HTTPS:8000): fails while checkpointed, kills the pod
	// CNPG operator monitors instance health directly via /pg/status.
	if targetIdx >= 0 {
		var ops []json.RawMessage
		if err := json.Unmarshal(patch, &ops); err != nil {
			return nil, fmt.Errorf("parsing patch ops: %w", err)
		}

		for _, probe := range []string{"startupProbe", "readinessProbe", "livenessProbe"} {
			removeOp, _ := json.Marshal(map[string]interface{}{
				"op":   "remove",
				"path": fmt.Sprintf("/spec/containers/%d/%s", targetIdx, probe),
			})
			ops = append(ops, removeOp)
		}

		patch, err = json.Marshal(ops)
		if err != nil {
			return nil, fmt.Errorf("marshaling patch ops: %w", err)
		}
	}

	logger.Info("injecting zeropod runtime",
		"cluster", cluster.Name,
		"podRole", containerName,
		"scaledownDuration", scaledownDuration,
		"patch", json.RawMessage(patch))

	return &lifecycle.OperatorLifecycleResponse{
		JsonPatch: patch,
	}, nil
}
