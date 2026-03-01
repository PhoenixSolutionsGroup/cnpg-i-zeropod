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
)

const (
	// Cluster annotations we read.
	annotationScaleToZeroEnabled     = "cnpg.io/scale-to-zero-enabled"
	annotationInactivitySeconds      = "cnpg.io/scale-to-zero-inactivity-seconds"
	defaultScaledownDuration         = "300s"

	// Zeropod annotations we inject.
	zeropodPortsMap          = "zeropod.ctrox.dev/ports-map"
	zeropodContainerNames    = "zeropod.ctrox.dev/container-names"
	zeropodScaledownDuration = "zeropod.ctrox.dev/scaledown-duration"

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

	// Set the RuntimeClass.
	runtimeClass := zeropodRuntimeClass
	mutatedPod.Spec.RuntimeClassName = &runtimeClass

	// Set zeropod annotations.
	if mutatedPod.Annotations == nil {
		mutatedPod.Annotations = make(map[string]string)
	}
	mutatedPod.Annotations[zeropodPortsMap] = "postgres=5432"
	mutatedPod.Annotations[zeropodContainerNames] = "postgres"
	mutatedPod.Annotations[zeropodScaledownDuration] = scaledownDuration

	// Find the postgres container and patch it for CRIU compatibility.
	pgIdx := -1
	for i := range mutatedPod.Spec.Containers {
		if mutatedPod.Spec.Containers[i].Name != "postgres" {
			continue
		}
		pgIdx = i
		c := &mutatedPod.Spec.Containers[i]

		// CRIU compatibility flags for the Go runtime:
		//   multipathtcp=0 — Go 1.21+ enables MPTCP (proto 262) by default,
		//     which CRIU cannot checkpoint ("Unsupported proto 262").
		//   pidfd=0 — Go 1.23+ uses pidfds for process tracking. CRIU
		//     restores pidfds but the Go runtime's internal state gets
		//     corrupted, causing cmd.Wait() to return prematurely. This
		//     makes the CNPG instance manager think PostgreSQL exited and
		//     restart it from scratch. Disabling pidfds forces waitpid(),
		//     which works on PIDs (preserved by CRIU).
		c.Env = append(c.Env, corev1.EnvVar{
			Name:  "GODEBUG",
			Value: "multipathtcp=0,pidfd=0",
		})

		break
	}

	// Generate the diff-based JSON patch.
	patch, err := object.CreatePatch(mutatedPod, pod)
	if err != nil {
		return nil, fmt.Errorf("creating patch: %w", err)
	}

	// Remove the liveness probe. CNPG adds probes AFTER calling the
	// lifecycle hook, so the pod we receive has no probes. We append a
	// RFC 6902 "remove" op targeting the final pod's liveness probe.
	// Any probe type is incompatible with zeropod scale-to-zero:
	//   - TCP on 5432: resets the eBPF idle timer, prevents scale-down
	//   - HTTPS on 8000: fails while checkpointed, kills the pod
	// CNPG's operator handles health monitoring independently.
	if pgIdx >= 0 {
		var ops []json.RawMessage
		if err := json.Unmarshal(patch, &ops); err != nil {
			return nil, fmt.Errorf("parsing patch ops: %w", err)
		}

		removeOp, _ := json.Marshal(map[string]interface{}{
			"op":   "remove",
			"path": fmt.Sprintf("/spec/containers/%d/livenessProbe", pgIdx),
		})
		ops = append(ops, removeOp)

		patch, err = json.Marshal(ops)
		if err != nil {
			return nil, fmt.Errorf("marshaling patch ops: %w", err)
		}
	}

	logger.Info("injecting zeropod runtime",
		"cluster", cluster.Name,
		"scaledownDuration", scaledownDuration,
		"patch", json.RawMessage(patch))

	return &lifecycle.OperatorLifecycleResponse{
		JsonPatch: patch,
	}, nil
}
