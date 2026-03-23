// Package controller implements the reconciliation controller that watches
// zeropod pod status labels and manages CNPG operator behavior accordingly.
package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	cnpgv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/machinery/pkg/log"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const (
	// Zeropod status label prefix set by the zeropod-manager DaemonSet.
	// Full label is status.zeropod.ctrox.dev/<container-name>.
	labelZeropodStatusPrefix = "status.zeropod.ctrox.dev/"

	// CNPG labels/annotations.
	labelCNPGCluster    = "cnpg.io/cluster"
	labelCNPGPodRole    = "cnpg.io/podRole"
	labelCNPGPoolerName = "cnpg.io/poolerName"

	// cnpg.io/fencedInstances is a JSON array of pod names that CNPG should
	// treat as "expected unavailable". Fenced instances report
	// MightBeUnavailable=true, so the reconciler skips them when waiting for
	// pods to be ready — allowing failover and other operations to proceed
	// while checkpointed instances are idle.
	annotationFencedInstances = "cnpg.io/fencedInstances"

	// Zeropod annotation used to identify managed pods.
	annotationZeropodPortsMap = "zeropod.ctrox.dev/ports-map"

	// Zeropod status values.
	statusScaledDown = "SCALED_DOWN"
	statusRunning    = "RUNNING"
)

// Reconciler watches pods with zeropod status labels and:
//   - Fences/unfences individual instances on scale-down/restore
//   - Suspends/resumes ScheduledBackups when all instances are down
type Reconciler struct {
	client.Client
}

// SetupWithManager registers the controller with the manager.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Pod{}).
		WithEventFilter(predicate.NewPredicateFuncs(func(obj client.Object) bool {
			labels := obj.GetLabels()
			_, hasCNPG := labels[labelCNPGCluster]
			if !hasCNPG {
				return false
			}
			annotations := obj.GetAnnotations()
			_, hasZeropod := annotations[annotationZeropodPortsMap]
			return hasZeropod
		})).
		Complete(r)
}

// Reconcile handles pod events for zeropod-managed CNPG pods.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithName("cnpg_i_zeropod_controller")

	pod := &corev1.Pod{}
	if err := r.Get(ctx, req.NamespacedName, pod); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	clusterName := pod.Labels[labelCNPGCluster]
	if clusterName == "" {
		return ctrl.Result{}, nil
	}

	// Find the zeropod status label (status.zeropod.ctrox.dev/<container>).
	var phase string
	for k, v := range pod.Labels {
		if strings.HasPrefix(k, labelZeropodStatusPrefix) {
			phase = v
			break
		}
	}

	// Pooler pods only need their service patched for publishNotReadyAddresses.
	if pod.Labels[labelCNPGPodRole] == "pooler" {
		if phase == statusScaledDown {
			return ctrl.Result{}, r.ensurePoolerPublishNotReadyAddresses(ctx, logger, pod)
		}
		return ctrl.Result{}, nil
	}

	cluster := &cnpgv1.Cluster{}
	if err := r.Get(ctx, types.NamespacedName{
		Name:      clusterName,
		Namespace: pod.Namespace,
	}, cluster); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	switch phase {
	case statusScaledDown:
		return r.onScaledDown(ctx, logger, pod, cluster)
	case statusRunning:
		return r.onRunning(ctx, logger, pod, cluster)
	}

	return ctrl.Result{}, nil
}

// onScaledDown fences the checkpointed instance so CNPG's reconciler skips it
// when waiting for pods to be ready. Also suspends backups when all instances
// are fenced.
func (r *Reconciler) onScaledDown(ctx context.Context, logger log.Logger, pod *corev1.Pod, cluster *cnpgv1.Cluster) (ctrl.Result, error) {
	fenced, err := getFencedInstances(cluster)
	if err != nil {
		return ctrl.Result{}, err
	}

	// Already fenced — nothing to do.
	if fenced.contains(pod.Name) {
		return ctrl.Result{}, nil
	}

	logger.Info("fencing checkpointed instance",
		"cluster", cluster.Name, "instance", pod.Name)

	fenced.add(pod.Name)
	if err := r.setFencedInstances(ctx, cluster, fenced); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.suspendScheduledBackups(ctx, logger, cluster); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.ensurePublishNotReadyAddresses(ctx, logger, cluster); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// onRunning unfences the restored instance so CNPG resumes managing it.
// Also resumes backups.
func (r *Reconciler) onRunning(ctx context.Context, logger log.Logger, pod *corev1.Pod, cluster *cnpgv1.Cluster) (ctrl.Result, error) {
	fenced, err := getFencedInstances(cluster)
	if err != nil {
		return ctrl.Result{}, err
	}

	// Not fenced — nothing to do.
	if !fenced.contains(pod.Name) {
		return ctrl.Result{}, nil
	}

	logger.Info("unfencing restored instance",
		"cluster", cluster.Name, "instance", pod.Name)

	fenced.remove(pod.Name)
	if err := r.setFencedInstances(ctx, cluster, fenced); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.resumeScheduledBackups(ctx, logger, cluster); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// fencedSet is an ordered set of instance names backed by a slice to produce
// stable JSON output.
type fencedSet struct {
	items []string
}

func (s *fencedSet) contains(name string) bool {
	for _, n := range s.items {
		if n == name {
			return true
		}
	}
	return false
}

func (s *fencedSet) add(name string) {
	if !s.contains(name) {
		s.items = append(s.items, name)
	}
}

func (s *fencedSet) remove(name string) {
	for i, n := range s.items {
		if n == name {
			s.items = append(s.items[:i], s.items[i+1:]...)
			return
		}
	}
}

func (s *fencedSet) isEmpty() bool {
	return len(s.items) == 0
}

// getFencedInstances parses the cnpg.io/fencedInstances annotation.
func getFencedInstances(cluster *cnpgv1.Cluster) (*fencedSet, error) {
	raw := cluster.Annotations[annotationFencedInstances]
	if raw == "" {
		return &fencedSet{}, nil
	}
	var names []string
	if err := json.Unmarshal([]byte(raw), &names); err != nil {
		return nil, fmt.Errorf("parsing fencedInstances annotation: %w", err)
	}
	return &fencedSet{items: names}, nil
}

// setFencedInstances patches the cluster's fencedInstances annotation.
func (r *Reconciler) setFencedInstances(ctx context.Context, cluster *cnpgv1.Cluster, fenced *fencedSet) error {
	patch := client.MergeFrom(cluster.DeepCopy())
	if cluster.Annotations == nil {
		cluster.Annotations = map[string]string{}
	}
	if fenced.isEmpty() {
		delete(cluster.Annotations, annotationFencedInstances)
	} else {
		data, err := json.Marshal(fenced.items)
		if err != nil {
			return fmt.Errorf("marshaling fencedInstances: %w", err)
		}
		cluster.Annotations[annotationFencedInstances] = string(data)
	}
	if err := r.Patch(ctx, cluster, patch); err != nil {
		return fmt.Errorf("updating fencedInstances: %w", err)
	}
	return nil
}

func (r *Reconciler) suspendScheduledBackups(ctx context.Context, logger log.Logger, cluster *cnpgv1.Cluster) error {
	var list cnpgv1.ScheduledBackupList
	if err := r.List(ctx, &list, client.InNamespace(cluster.Namespace)); err != nil {
		return fmt.Errorf("listing scheduled backups: %w", err)
	}

	for i := range list.Items {
		sched := &list.Items[i]
		if sched.Spec.Cluster.Name != cluster.Name {
			continue
		}
		if sched.Spec.Suspend != nil && *sched.Spec.Suspend {
			continue
		}

		logger.Info("suspending scheduled backup", "backup", sched.Name)
		p := client.MergeFrom(sched.DeepCopy())
		suspend := true
		sched.Spec.Suspend = &suspend
		if err := r.Patch(ctx, sched, p); err != nil {
			return fmt.Errorf("suspending backup %s: %w", sched.Name, err)
		}
	}
	return nil
}

func (r *Reconciler) resumeScheduledBackups(ctx context.Context, logger log.Logger, cluster *cnpgv1.Cluster) error {
	var list cnpgv1.ScheduledBackupList
	if err := r.List(ctx, &list, client.InNamespace(cluster.Namespace)); err != nil {
		return fmt.Errorf("listing scheduled backups: %w", err)
	}

	for i := range list.Items {
		sched := &list.Items[i]
		if sched.Spec.Cluster.Name != cluster.Name {
			continue
		}
		if sched.Spec.Suspend == nil || !*sched.Spec.Suspend {
			continue
		}

		logger.Info("resuming scheduled backup", "backup", sched.Name)
		p := client.MergeFrom(sched.DeepCopy())
		suspend := false
		sched.Spec.Suspend = &suspend
		if err := r.Patch(ctx, sched, p); err != nil {
			return fmt.Errorf("resuming backup %s: %w", sched.Name, err)
		}
	}
	return nil
}

// ensurePublishNotReadyAddresses patches the CNPG services (-rw, -ro, -r) to
// set publishNotReadyAddresses: true. Without this, checkpointed pods are
// removed from service endpoints (they're not Ready), so no TCP traffic can
// reach zeropod to trigger a restore — causing a permanent deadlock.
func (r *Reconciler) ensurePublishNotReadyAddresses(ctx context.Context, logger log.Logger, cluster *cnpgv1.Cluster) error {
	suffixes := []string{"-rw", "-ro", "-r"}
	for _, suffix := range suffixes {
		svc := &corev1.Service{}
		svcName := types.NamespacedName{
			Name:      cluster.Name + suffix,
			Namespace: cluster.Namespace,
		}
		if err := r.Get(ctx, svcName, svc); err != nil {
			return client.IgnoreNotFound(err)
		}
		if svc.Spec.PublishNotReadyAddresses {
			continue
		}
		logger.Info("patching service with publishNotReadyAddresses",
			"service", svc.Name)
		patch := client.MergeFrom(svc.DeepCopy())
		svc.Spec.PublishNotReadyAddresses = true
		if err := r.Patch(ctx, svc, patch); err != nil {
			return fmt.Errorf("patching service %s: %w", svc.Name, err)
		}
	}
	return nil
}

// ensurePoolerPublishNotReadyAddresses patches the Pooler's service to set
// publishNotReadyAddresses: true, so checkpointed pgbouncer pods remain in
// service endpoints and can be woken by incoming TCP connections.
func (r *Reconciler) ensurePoolerPublishNotReadyAddresses(ctx context.Context, logger log.Logger, pod *corev1.Pod) error {
	poolerName := pod.Labels[labelCNPGPoolerName]
	if poolerName == "" {
		return nil
	}
	svc := &corev1.Service{}
	if err := r.Get(ctx, types.NamespacedName{
		Name:      poolerName,
		Namespace: pod.Namespace,
	}, svc); err != nil {
		return client.IgnoreNotFound(err)
	}
	if svc.Spec.PublishNotReadyAddresses {
		return nil
	}
	logger.Info("patching pooler service with publishNotReadyAddresses",
		"service", svc.Name)
	patch := client.MergeFrom(svc.DeepCopy())
	svc.Spec.PublishNotReadyAddresses = true
	if err := r.Patch(ctx, svc, patch); err != nil {
		return fmt.Errorf("patching pooler service %s: %w", svc.Name, err)
	}
	return nil
}
