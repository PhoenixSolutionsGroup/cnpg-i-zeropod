// Package metadata contains the metadata of this plugin.
package metadata

import "github.com/cloudnative-pg/cnpg-i/pkg/identity"

// PluginName is the name of the plugin, following CNPG-I naming conventions.
const PluginName = "cnpg-i-zeropod.io"

// Data is the metadata of this plugin.
var Data = identity.GetPluginMetadataResponse{
	Name:          PluginName,
	Version:       "0.1.0",
	DisplayName:   "CNPG Zeropod Scale-to-Zero",
	Description:   "Injects zeropod runtime class and annotations into CNPG pods for CRIU-based scale-to-zero",
	ProjectUrl:    "https://github.com/cnpg-i-zeropod/cnpg-i-zeropod",
	RepositoryUrl: "https://github.com/cnpg-i-zeropod/cnpg-i-zeropod",
	License:       "Apache-2.0",
	LicenseUrl:    "https://github.com/cnpg-i-zeropod/cnpg-i-zeropod/blob/main/LICENSE",
	Maturity:      "alpha",
}
