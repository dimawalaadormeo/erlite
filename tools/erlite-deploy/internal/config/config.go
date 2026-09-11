// Package config defines the canonical deployment configuration: the single
// schema that both the GUI wizard and any AI front-end (agentic or
// chat-only) fill in before calling the generator. Neither front-end has its
// own notion of what a valid deployment looks like -- this package is the
// only place that lives.
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// Target identifies which deployment target a config is for. Kubernetes and
// the two Proxmox modes are part of the schema (see docs/deployment-system-plan.md)
// but do not yet have a generator implementation; Validate reports that
// explicitly rather than letting Generate fail unhelpfully.
type Target string

const (
	TargetDocker     Target = "docker"
	TargetPodman     Target = "podman"
	TargetKubernetes Target = "kubernetes"
	TargetServer     Target = "server"
	TargetProxmoxVM  Target = "proxmox_vm"
	TargetProxmoxLXC Target = "proxmox_lxc"
)

var knownTargets = map[Target]bool{
	TargetDocker:     true,
	TargetPodman:     true,
	TargetKubernetes: true,
	TargetServer:     true,
	TargetProxmoxVM:  true,
	TargetProxmoxLXC: true,
}

// implementedTargets are the targets Generate can actually produce output
// for today. Kept separate from knownTargets so the schema/question flow
// can describe the full plan while Validate gives an honest, specific error
// for the rest instead of silently mis-generating.
var implementedTargets = map[Target]bool{
	TargetDocker: true,
	TargetPodman: true,
	TargetServer: true,
}

func Implemented(t Target) bool { return implementedTargets[t] }

// TLSMode controls whether erlite-deploy generates a self-signed CA and
// per-node certificates, or expects the operator to supply their own.
type TLSMode string

const (
	TLSGenerateSelfSigned TLSMode = "generate-self-signed"
	TLSProvideExisting    TLSMode = "provide-existing"
)

// Node is one member of the cluster being deployed. Exactly one node in a
// Config must have Seed set -- it is the node that runs `erlite init-cluster`
// while every other node runs `erlite join <seed>`.
type Node struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Seed bool   `json:"seed,omitempty"`
}

// Config is the canonical deployment configuration. Every field an operator
// (human or AI) can set lives here; the GUI renders a form from it, the AI
// path validates a filled-in instance of it, and every generator reads only
// from it -- see docs/deployment-system-plan.md section 2 for why that
// single-source-of-truth shape matters.
type Config struct {
	Target Target `json:"target"`

	// Cluster topology
	ClusterName       string `json:"clusterName"`
	Nodes             []Node `json:"nodes"`
	ReplicationFactor int    `json:"replicationFactor,omitempty"`

	// Storage
	StoragePath      string `json:"storagePath,omitempty"`
	DiskSizeGiB      int    `json:"diskSizeGiB,omitempty"`
	DiskReserveBytes int64  `json:"diskReserveBytes,omitempty"`

	// Networking
	ClusterDistPortRange string  `json:"clusterDistPortRange,omitempty"`
	APIPort              int     `json:"apiPort,omitempty"`
	TLSMode              TLSMode `json:"tlsMode,omitempty"`
	TLSCertPath          string  `json:"tlsCertPath,omitempty"`
	TLSKeyPath           string  `json:"tlsKeyPath,omitempty"`
	Firewall             bool    `json:"firewall,omitempty"`

	// Security
	AdminCredentialSource string `json:"adminCredentialSource,omitempty"`

	// Runtime / version pinning
	OTPVersion       string `json:"otpVersion,omitempty"`
	ErliteReleaseRef string `json:"erliteReleaseRef,omitempty"`
	SQLiteBuildID    string `json:"sqliteBuildId,omitempty"`

	// Resource sizing
	CPUPerNode    string `json:"cpuPerNode,omitempty"`
	MemoryPerNode string `json:"memoryPerNode,omitempty"`

	// Observability
	MetricsScrapeEnabled bool   `json:"metricsScrapeEnabled,omitempty"`
	LogShipping          string `json:"logShipping,omitempty"`

	// Container targets (docker, podman, kubernetes)
	ImageSource     string `json:"imageSource,omitempty"` // "build" | "pull"
	ImageRef        string `json:"imageRef,omitempty"`
	Registry        string `json:"registry,omitempty"`
	K8sNamespace    string `json:"k8sNamespace,omitempty"`
	K8sStorageClass string `json:"k8sStorageClass,omitempty"`

	// Server/VM targets (server, proxmox_vm, proxmox_lxc)
	OSFamily      string `json:"osFamily,omitempty"`
	SSHUser       string `json:"sshUser,omitempty"`
	CloudProvider string `json:"cloudProvider,omitempty"`

	// Proxmox targets
	ProxmoxAPIEndpoint string `json:"proxmoxApiEndpoint,omitempty"`
	ProxmoxNode        string `json:"proxmoxNode,omitempty"`
	ProxmoxTemplate    string `json:"proxmoxTemplate,omitempty"`
	ProxmoxBridge      string `json:"proxmoxBridge,omitempty"`
	ProxmoxStaticIP    bool   `json:"proxmoxStaticIp,omitempty"`
	CoresPerNode       int    `json:"coresPerNode,omitempty"`
	RAMMiBPerNode      int    `json:"ramMiBPerNode,omitempty"`

	// Post-deploy behavior
	AutoBootstrap   bool   `json:"autoBootstrap,omitempty"`
	UpgradeStrategy string `json:"upgradeStrategy,omitempty"`
}

// erliteDefaultDiskReserveBytes mirrors erlite_placement:?DEFAULT_DISK_RESERVE
// in apps/erlite_core/src/erlite_placement.erl, so a generated deployment's
// documented disk headroom actually matches what the placement admission
// gate will enforce once databases start landing on these nodes.
const erliteDefaultDiskReserveBytes = 1073741824

// ApplyDefaults fills in every field that has a sane default, and picks a
// seed node if none was marked. It does not fill in fields that have no safe
// default (ClusterName, Nodes, target-specific required fields) -- those
// missing is what Validate reports.
func (c *Config) ApplyDefaults() {
	if c.ReplicationFactor == 0 {
		c.ReplicationFactor = 3
	}
	if c.StoragePath == "" {
		c.StoragePath = "/var/lib/erlite"
	}
	if c.DiskReserveBytes == 0 {
		c.DiskReserveBytes = erliteDefaultDiskReserveBytes
	}
	if c.ClusterDistPortRange == "" {
		c.ClusterDistPortRange = "9100-9105"
	}
	if c.APIPort == 0 {
		c.APIPort = 4433
	}
	if c.TLSMode == "" {
		c.TLSMode = TLSGenerateSelfSigned
	}
	if c.AdminCredentialSource == "" {
		c.AdminCredentialSource = "generate"
	}
	if c.OTPVersion == "" {
		c.OTPVersion = "26.2"
	}
	if c.LogShipping == "" {
		c.LogShipping = "none"
	}
	if c.UpgradeStrategy == "" {
		c.UpgradeStrategy = "rolling"
	}
	if (c.Target == TargetDocker || c.Target == TargetPodman) && c.ImageSource == "" {
		c.ImageSource = "build"
	}

	hasSeed := false
	for _, n := range c.Nodes {
		if n.Seed {
			hasSeed = true
			break
		}
	}
	if !hasSeed && len(c.Nodes) > 0 {
		c.Nodes[0].Seed = true
	}
}

// Validate returns every problem with c, or nil if c is ready to generate
// from. It is deliberately exhaustive rather than fail-fast: an AI or GUI
// calling this once should get every fix it needs to make, not one error at
// a time.
func (c *Config) Validate() []string {
	var errs []string

	if c.Target == "" {
		errs = append(errs, "target is required")
	} else if !knownTargets[c.Target] {
		errs = append(errs, fmt.Sprintf("target %q is not a recognized target", c.Target))
	} else if !implementedTargets[c.Target] {
		errs = append(errs, fmt.Sprintf("target %q is defined in the schema but its generator is not implemented yet (see docs/deployment-system-plan.md)", c.Target))
	}

	if c.ClusterName == "" {
		errs = append(errs, "clusterName is required")
	}

	if len(c.Nodes) < 3 {
		errs = append(errs, fmt.Sprintf("at least 3 nodes are required (got %d) -- Erlite's minimum production deployment is 3 servers", len(c.Nodes)))
	}

	seeds := 0
	names := map[string]bool{}
	for i, n := range c.Nodes {
		if n.Name == "" {
			errs = append(errs, fmt.Sprintf("nodes[%d].name is required", i))
		} else if names[n.Name] {
			errs = append(errs, fmt.Sprintf("duplicate node name %q", n.Name))
		} else {
			names[n.Name] = true
		}
		if n.Host == "" {
			errs = append(errs, fmt.Sprintf("nodes[%d].host is required", i))
		}
		if n.Seed {
			seeds++
		}
	}
	if len(c.Nodes) > 0 && seeds != 1 {
		errs = append(errs, fmt.Sprintf("exactly one node must be marked as the seed (found %d)", seeds))
	}

	if c.ReplicationFactor <= 0 {
		errs = append(errs, "replicationFactor must be positive")
	} else if c.ReplicationFactor > len(c.Nodes) {
		errs = append(errs, fmt.Sprintf("replicationFactor (%d) cannot exceed node count (%d)", c.ReplicationFactor, len(c.Nodes)))
	}

	if c.StoragePath == "" {
		errs = append(errs, "storagePath is required")
	}
	if c.APIPort <= 0 || c.APIPort > 65535 {
		errs = append(errs, "apiPort must be between 1 and 65535")
	}

	switch c.TLSMode {
	case TLSGenerateSelfSigned:
		// nothing further required
	case TLSProvideExisting:
		if c.TLSCertPath == "" || c.TLSKeyPath == "" {
			errs = append(errs, "tlsCertPath and tlsKeyPath are required when tlsMode is \"provide-existing\"")
		}
	default:
		errs = append(errs, fmt.Sprintf("tlsMode %q is not recognized", c.TLSMode))
	}

	switch c.Target {
	case TargetDocker, TargetPodman:
		if c.ImageSource != "build" && c.ImageSource != "pull" {
			errs = append(errs, "imageSource must be \"build\" or \"pull\" for container targets")
		}
		if c.ImageSource == "pull" && c.ImageRef == "" {
			errs = append(errs, "imageRef is required when imageSource is \"pull\"")
		}
	case TargetServer:
		if c.OSFamily == "" {
			errs = append(errs, "osFamily is required for the server target")
		}
		if c.SSHUser == "" {
			errs = append(errs, "sshUser is required for the server target")
		}
	case TargetKubernetes:
		if c.K8sNamespace == "" {
			errs = append(errs, "k8sNamespace is required for the kubernetes target")
		}
	case TargetProxmoxVM, TargetProxmoxLXC:
		if c.ProxmoxAPIEndpoint == "" {
			errs = append(errs, "proxmoxApiEndpoint is required for proxmox targets")
		}
		if c.ProxmoxNode == "" {
			errs = append(errs, "proxmoxNode is required for proxmox targets")
		}
	}

	return errs
}

// Load reads a config from path, applies defaults, and returns it
// unvalidated -- callers decide whether to check Validate() themselves
// (the CLI's validate/generate subcommands do).
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parsing config file as JSON: %w", err)
	}
	c.ApplyDefaults()
	return &c, nil
}

// Quorum returns the minimum number of healthy replicas Erlite requires for
// consistent writes at this config's replication factor (2 of 3 by default).
func (c *Config) Quorum() int {
	return c.ReplicationFactor/2 + 1
}

// SeedNode returns the node marked as seed. Callers should only use this
// after ApplyDefaults/Validate have run, which guarantee exactly one exists.
func (c *Config) SeedNode() (Node, bool) {
	for _, n := range c.Nodes {
		if n.Seed {
			return n, true
		}
	}
	return Node{}, false
}

// OtherNodes returns every node except the seed, in the order given.
func (c *Config) OtherNodes() []Node {
	var out []Node
	for _, n := range c.Nodes {
		if !n.Seed {
			out = append(out, n)
		}
	}
	return out
}

// SeedNodesList returns every node's Erlite node name ("name@host"), which
// is what the seed_nodes configuration entry from ERLITE_PROJECT.md section 5
// expects.
func (c *Config) SeedNodesList() []string {
	out := make([]string, 0, len(c.Nodes))
	for _, n := range c.Nodes {
		out = append(out, n.Name+"@"+n.Host)
	}
	return out
}
