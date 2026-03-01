// Package controller implements the command to start the reconciliation controller.
package controller

import (
	"fmt"
	"os"

	cnpgv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/machinery/pkg/log"
	"github.com/spf13/cobra"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/cnpg-i-zeropod/cnpg-i-zeropod/internal/controller"
)

// NewCmd creates the `controller` subcommand that starts the reconciliation controller.
func NewCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "controller",
		Short: "Start the zeropod reconciliation controller",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return run(cmd)
		},
	}
}

func run(cmd *cobra.Command) error {
	logger := log.FromContext(cmd.Context())

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return fmt.Errorf("adding client-go scheme: %w", err)
	}
	if err := cnpgv1.AddToScheme(scheme); err != nil {
		return fmt.Errorf("adding CNPG scheme: %w", err)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: "",
	})
	if err != nil {
		return fmt.Errorf("creating manager: %w", err)
	}

	reconciler := &controller.Reconciler{Client: mgr.GetClient()}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		return fmt.Errorf("setting up controller: %w", err)
	}

	logger.Info("starting reconciliation controller")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "controller exited")
		os.Exit(1)
	}
	return nil
}
