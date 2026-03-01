// Package controller implements the reconciliation controller that watches
// zeropod pod status labels and manages CNPG operator behavior accordingly.
package controller

import (
	"context"
	"fmt"

	cnpgv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/machinery/pkg/log"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const (
	// Zeropod status label set by the zeropod-manager DaemonSet.
	labelZeropodStatus = "status.zeropod.ctrox.dev/postgres"

	// CNPG labels/annotations.
	labelCNPGCluster         = "cnpg.io/cluster"
	annotationReconciliation = "cnpg.io/reconciliationLoop"

	// Zeropod annotation used to identify managed pods.
	annotationZeropodPortsMap = "zeropod.ctrox.dev/ports-map"

	// Zeropod status values.
	statusScaledDown = "SCALED_DOWN"
	statusRunning    = "RUNNING"
)

// Reconciler watches pods with zeropod status labels and:
//   - Toggles CNPG reconciliation loop on scale-down/restore
//   - Suspends/resumes ScheduledBackups
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
			annotations := obj.GetAnnotations()
			_, hasZeropod := annotations[annotationZeropodPortsMap]
			return hasCNPG && hasZeropod
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

	phase := pod.Labels[labelZeropodStatus]

	cluster := &cnpgv1.Cluster{}
	if err := r.Get(ctx, types.NamespacedName{
		Name:      clusterName,
		Namespace: pod.Namespace,
	}, cluster); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	switch phase {
	case statusScaledDown:
		return r.onScaledDown(ctx, logger, cluster)
	case statusRunning:
		return r.onRunning(ctx, logger, cluster)
	}

	return ctrl.Result{}, nil
}

// onScaledDown disables the CNPG reconciliation loop and suspends backups.
func (r *Reconciler) onScaledDown(ctx context.Context, logger log.Logger, cluster *cnpgv1.Cluster) (ctrl.Result, error) {
	if cluster.Annotations[annotationReconciliation] == "disabled" {
		return ctrl.Result{}, nil
	}

	logger.Info("pod scaled down, disabling CNPG reconciliation",
		"cluster", cluster.Name)

	patch := client.MergeFrom(cluster.DeepCopy())
	if cluster.Annotations == nil {
		cluster.Annotations = map[string]string{}
	}
	cluster.Annotations[annotationReconciliation] = "disabled"
	if err := r.Patch(ctx, cluster, patch); err != nil {
		return ctrl.Result{}, fmt.Errorf("disabling reconciliation: %w", err)
	}

	if err := r.suspendScheduledBackups(ctx, logger, cluster); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// onRunning re-enables the CNPG reconciliation loop and resumes backups.
func (r *Reconciler) onRunning(ctx context.Context, logger log.Logger, cluster *cnpgv1.Cluster) (ctrl.Result, error) {
	if _, exists := cluster.Annotations[annotationReconciliation]; !exists {
		return ctrl.Result{}, nil
	}

	logger.Info("pod restored, re-enabling CNPG reconciliation",
		"cluster", cluster.Name)

	patch := client.MergeFrom(cluster.DeepCopy())
	delete(cluster.Annotations, annotationReconciliation)
	if err := r.Patch(ctx, cluster, patch); err != nil {
		return ctrl.Result{}, fmt.Errorf("enabling reconciliation: %w", err)
	}

	if err := r.resumeScheduledBackups(ctx, logger, cluster); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
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
