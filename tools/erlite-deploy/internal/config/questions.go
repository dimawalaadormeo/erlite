package config

// Question describes one thing the operator needs to decide, independent of
// who's asking. Both a GUI form and an AI interview are driven from this
// same list -- see docs/deployment-system-plan.md section 5.1: this is the
// artifact that keeps the two front-ends' question flow identical.
type Question struct {
	ID        string   `json:"id"` // JSON field path this answers, e.g. "clusterName" or "nodes"
	Prompt    string   `json:"prompt"`
	Help      string   `json:"help,omitempty"`
	Type      string   `json:"type"` // "string" | "int" | "bool" | "enum" | "list"
	Enum      []string `json:"enum,omitempty"`
	Default   string   `json:"default,omitempty"`
	Required  bool     `json:"required"`
	AppliesTo []Target `json:"appliesTo,omitempty"` // empty means "all targets"
}

// Questions returns the full canonical question set, in interview order.
// Group boundaries match docs/deployment-system-plan.md section 3.
func Questions() []Question {
	return []Question{
		// Target selection
		{ID: "target", Type: "enum", Required: true,
			Prompt: "Which deployment target?",
			Enum:   []string{string(TargetDocker), string(TargetPodman), string(TargetKubernetes), string(TargetServer), string(TargetProxmoxVM), string(TargetProxmoxLXC)},
			Help:   "kubernetes, proxmox_vm, and proxmox_lxc are defined but not yet generatable -- see docs/deployment-system-plan.md."},

		// Cluster topology
		{ID: "clusterName", Type: "string", Required: true,
			Prompt: "What should this cluster be called?"},
		{ID: "nodes", Type: "list", Required: true,
			Prompt: "List the nodes (name, host/IP, which one is the seed). At least 3.",
			Help:   "The seed node is the one that runs `erlite init-cluster`; every other node runs `erlite join <seed>`."},
		{ID: "replicationFactor", Type: "int", Default: "3",
			Prompt: "Replication factor?", Help: "Default and recommended value is 3."},

		// Storage
		{ID: "storagePath", Type: "string", Default: "/var/lib/erlite",
			Prompt: "Storage path on each node?"},
		{ID: "diskSizeGiB", Type: "int",
			Prompt: "Disk size per node (GiB)?"},
		{ID: "diskReserveBytes", Type: "int", Default: "1073741824",
			Prompt: "Disk reserve, in bytes, below which a node stops accepting new database replicas?",
			Help:   "Matches Erlite's placement admission gate default (1 GiB). Size disks with this floor in mind."},

		// Networking
		{ID: "clusterDistPortRange", Type: "string", Default: "9100-9105",
			Prompt: "Erlang distribution port range between nodes?"},
		{ID: "apiPort", Type: "int", Default: "4433",
			Prompt: "External HTTP/JSON API port?"},
		{ID: "tlsMode", Type: "enum", Default: string(TLSGenerateSelfSigned),
			Enum:   []string{string(TLSGenerateSelfSigned), string(TLSProvideExisting)},
			Prompt: "Generate a self-signed CA and certificates, or provide your own?"},
		{ID: "tlsCertPath", Type: "string",
			Prompt: "Path to an existing certificate?", Help: "Only asked when tlsMode is provide-existing."},
		{ID: "tlsKeyPath", Type: "string",
			Prompt: "Path to the matching private key?", Help: "Only asked when tlsMode is provide-existing."},
		{ID: "firewall", Type: "bool", Default: "true",
			Prompt: "Generate firewall rules for the API and distribution ports?"},

		// Security
		{ID: "adminCredentialSource", Type: "enum", Default: "generate",
			Enum:   []string{"generate", "prompt", "external"},
			Prompt: "How should the admin credential be provided: generated, prompted for, or from an external secret manager?"},

		// Runtime/version pinning
		{ID: "otpVersion", Type: "string", Default: "26.2",
			Prompt: "Pinned Erlang/OTP version?"},
		{ID: "erliteReleaseRef", Type: "string", Required: true,
			Prompt: "Erlite release reference (git tag, release tarball URL, or container image tag)?",
			Help:   "All replicas in a group must run a compatible, pinned build -- see ERLITE_PROJECT.md section 11."},
		{ID: "sqliteBuildId", Type: "string",
			Prompt: "Pinned SQLite build identifier, if you track one separately from the Erlite release?"},

		// Resource sizing
		{ID: "cpuPerNode", Type: "string",
			Prompt: "CPU allocation per node (e.g. \"2\" or \"2000m\")?"},
		{ID: "memoryPerNode", Type: "string",
			Prompt: "Memory allocation per node (e.g. \"4Gi\")?"},

		// Observability
		{ID: "metricsScrapeEnabled", Type: "bool", Default: "false",
			Prompt: "Wire up /v1/metrics for scraping?"},
		{ID: "logShipping", Type: "enum", Default: "none",
			Enum:   []string{"none", "syslog", "file"},
			Prompt: "Ship logs anywhere beyond local files?"},

		// Container-specific
		{ID: "imageSource", Type: "enum", Default: "build",
			Enum: []string{"build", "pull"}, AppliesTo: []Target{TargetDocker, TargetPodman, TargetKubernetes},
			Prompt: "Build the Erlite image from source, or pull a published image?"},
		{ID: "imageRef", Type: "string", AppliesTo: []Target{TargetDocker, TargetPodman, TargetKubernetes},
			Prompt: "Image reference to pull?", Help: "Only asked when imageSource is pull."},
		{ID: "registry", Type: "string", AppliesTo: []Target{TargetDocker, TargetPodman, TargetKubernetes},
			Prompt: "Container registry, if not the default?"},
		{ID: "k8sNamespace", Type: "string", Required: true, AppliesTo: []Target{TargetKubernetes},
			Prompt: "Kubernetes namespace?"},
		{ID: "k8sStorageClass", Type: "string", AppliesTo: []Target{TargetKubernetes},
			Prompt: "StorageClass for the per-node PersistentVolumeClaims?"},

		// Server/VM-specific
		{ID: "osFamily", Type: "string", Required: true, AppliesTo: []Target{TargetServer, TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "OS family of the target hosts (e.g. debian, ubuntu, rhel)?"},
		{ID: "sshUser", Type: "string", Required: true, AppliesTo: []Target{TargetServer, TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "SSH user with sudo on the target hosts?"},
		{ID: "cloudProvider", Type: "enum", Default: "none", AppliesTo: []Target{TargetServer},
			Enum:   []string{"none", "aws", "gcp", "azure", "other"},
			Prompt: "Cloud provider, if any -- selects cloud-init vs. a plain provisioning script?"},

		// Proxmox-specific
		{ID: "proxmoxApiEndpoint", Type: "string", Required: true, AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "Proxmox API endpoint?"},
		{ID: "proxmoxNode", Type: "string", Required: true, AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "Which Proxmox node should host these guests?"},
		{ID: "proxmoxTemplate", Type: "string", AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "Template or base image to clone?"},
		{ID: "proxmoxBridge", Type: "string", Default: "vmbr0", AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "Network bridge?"},
		{ID: "proxmoxStaticIp", Type: "bool", Default: "false", AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "Assign static IPs, or use DHCP?"},
		{ID: "coresPerNode", Type: "int", AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "CPU cores per guest?"},
		{ID: "ramMiBPerNode", Type: "int", AppliesTo: []Target{TargetProxmoxVM, TargetProxmoxLXC},
			Prompt: "RAM (MiB) per guest?"},

		// Post-deploy
		{ID: "autoBootstrap", Type: "bool", Default: "false",
			Prompt: "After generating, also execute the bootstrap scripts (vs. generate only)?",
			Help:   "Provisions real infrastructure and bootstraps a real Raft cluster -- always confirm explicitly before doing this, never run it unattended."},
		{ID: "upgradeStrategy", Type: "enum", Default: "rolling",
			Enum:   []string{"none", "rolling"},
			Prompt: "Rolling upgrade support?"},
	}
}

// QuestionsForTarget filters Questions() to those relevant to t: every
// question with an empty AppliesTo, plus those that explicitly list t.
func QuestionsForTarget(t Target) []Question {
	all := Questions()
	out := make([]Question, 0, len(all))
	for _, q := range all {
		if len(q.AppliesTo) == 0 {
			out = append(out, q)
			continue
		}
		for _, at := range q.AppliesTo {
			if at == t {
				out = append(out, q)
				break
			}
		}
	}
	return out
}
