// Package plugin implements the command to start the CNPG-I plugin server.
package plugin

import (
	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/http"
	"github.com/cloudnative-pg/cnpg-i/pkg/lifecycle"
	"github.com/spf13/cobra"
	"google.golang.org/grpc"

	"github.com/cnpg-i-zeropod/cnpg-i-zeropod/internal/identity"
	lifecycleImpl "github.com/cnpg-i-zeropod/cnpg-i-zeropod/internal/lifecycle"
)

// NewCmd creates the `plugin` subcommand that starts the gRPC server.
func NewCmd() *cobra.Command {
	cmd := http.CreateMainCmd(identity.Implementation{}, func(server *grpc.Server) error {
		lifecycle.RegisterOperatorLifecycleServer(server, lifecycleImpl.Implementation{})
		return nil
	})

	cmd.Use = "plugin"
	cmd.Short = "Start the CNPG-I zeropod plugin server"

	return cmd
}
