package main

import (
	"fmt"
	"os"

	"github.com/cloudnative-pg/machinery/pkg/log"
	"github.com/spf13/cobra"

	controllerCmd "github.com/cnpg-i-zeropod/cnpg-i-zeropod/cmd/controller"
	"github.com/cnpg-i-zeropod/cnpg-i-zeropod/cmd/plugin"
)

func main() {
	cobra.EnableTraverseRunHooks = true

	logFlags := &log.Flags{}
	rootCmd := &cobra.Command{
		Use:   "cnpg-i-zeropod",
		Short: "CNPG-I plugin for zeropod scale-to-zero",
		PersistentPreRun: func(cmd *cobra.Command, _ []string) {
			logFlags.ConfigureLogging()
			cmd.SetContext(log.IntoContext(cmd.Context(), log.GetLogger()))
		},
	}

	logFlags.AddFlags(rootCmd.PersistentFlags())
	rootCmd.AddCommand(plugin.NewCmd())
	rootCmd.AddCommand(controllerCmd.NewCmd())

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}
