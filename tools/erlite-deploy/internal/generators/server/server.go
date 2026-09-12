// Package server generates the bare server / cloud VM deployment target:
// per-node install.sh, a systemd unit, TLS generation, and an orchestrator
// that sequences init-cluster/join across every node over SSH.
package server

import (
	"bytes"
	"embed"
	"fmt"
	"strings"
	"text/template"

	"erlite-deploy/internal/artifact"
	"erlite-deploy/internal/config"
	"erlite-deploy/internal/guide"
	"erlite-deploy/internal/secret"
)

//go:embed templates/*.tmpl
var templateFS embed.FS

type nodeData struct {
	Config                 *config.Config
	Node                   config.Node
	SeedNodesEnv           string
	DistPortRangeUfw       string
	DistPortRangeFirewalld string
	Firewall               bool
}

type clusterData struct {
	Config     *config.Config
	SeedNode   config.Node
	OtherNodes []config.Node
}

func render(name string, data any) ([]byte, error) {
	tmpl, err := template.New(name).ParseFS(templateFS, "templates/"+name)
	if err != nil {
		return nil, fmt.Errorf("parsing template %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, name, data); err != nil {
		return nil, fmt.Errorf("rendering template %s: %w", name, err)
	}
	return buf.Bytes(), nil
}

// ufwRange turns a "9100-9105" style range into ufw's "9100:9105" syntax.
func ufwRange(r string) string {
	return strings.ReplaceAll(r, "-", ":")
}

// Generate produces the server/VM target's output for cfg. cfg must already
// have passed config.Validate() for the server target.
func Generate(cfg *config.Config) ([]artifact.File, error) {
	seed, ok := cfg.SeedNode()
	if !ok {
		return nil, fmt.Errorf("no seed node found in config (this should have been caught by Validate)")
	}
	others := cfg.OtherNodes()
	distUfw := ufwRange(cfg.ClusterDistPortRange)
	seedNodesEnv := strings.Join(cfg.SeedNodesList(), ",")

	var files []artifact.File

	for _, n := range cfg.Nodes {
		content, err := render("install.sh.tmpl", nodeData{
			Config:                 cfg,
			Node:                   n,
			SeedNodesEnv:           seedNodesEnv,
			DistPortRangeUfw:       distUfw,
			DistPortRangeFirewalld: cfg.ClusterDistPortRange,
			Firewall:               cfg.Firewall,
		})
		if err != nil {
			return nil, err
		}
		files = append(files, artifact.File{Name: fmt.Sprintf("install-%s.sh", n.Name), Content: content, Mode: 0o755})
	}

	svc, err := render("erlite.service.tmpl", cfg)
	if err != nil {
		return nil, err
	}
	files = append(files, artifact.File{Name: "erlite.service", Content: svc, Mode: 0o644})

	cd := clusterData{Config: cfg, SeedNode: seed, OtherNodes: others}

	bootstrap, err := render("bootstrap-cluster.sh.tmpl", cd)
	if err != nil {
		return nil, err
	}
	files = append(files, artifact.File{Name: "bootstrap-cluster.sh", Content: bootstrap, Mode: 0o755})

	provision, err := render("provision-all.sh.tmpl", cd)
	if err != nil {
		return nil, err
	}
	files = append(files, artifact.File{Name: "provision-all.sh", Content: provision, Mode: 0o755})

	if cfg.TLSMode == config.TLSGenerateSelfSigned {
		tls, err := render("tls-gen.sh.tmpl", cfg)
		if err != nil {
			return nil, err
		}
		files = append(files, artifact.File{Name: "tls-gen.sh", Content: tls, Mode: 0o755})
	}

	if cfg.AdminCredentialSource == "generate" {
		token, err := secret.Token(32)
		if err != nil {
			return nil, err
		}
		content := fmt.Sprintf(
			"# Generated admin credential for cluster %q.\n"+
				"# Move this file somewhere secure and rotate the credential -- see\n"+
				"# DEPLOY_GUIDE.md \"Security follow-ups\".\nADMIN_TOKEN=%s\n",
			cfg.ClusterName, token)
		files = append(files, artifact.File{Name: "admin-credentials.txt", Content: []byte(content), Mode: 0o600})
	}

	guideFile, err := guide.Render(guide.Input{
		Config:      cfg,
		TargetLabel: "Server / VM",
		Prerequisites: []string{
			fmt.Sprintf("SSH access as %q with sudo to all %d nodes", cfg.SSHUser, len(cfg.Nodes)),
			fmt.Sprintf("%s hosts that can reach each other on the distribution port range %s", cfg.OSFamily, cfg.ClusterDistPortRange),
			fmt.Sprintf("Port %d reachable from clients that will talk to the cluster", cfg.APIPort),
			"A way to install the pinned Erlite release referenced in install-*.sh (tarball, internal registry, or build from source)",
		},
		InstallSteps: []string{
			"Copy this entire output directory to a machine with SSH access to every node.",
			"Run `./provision-all.sh` to copy each node's install-<name>.sh and erlite.service to its host, run it there, and then bootstrap the cluster automatically. Or, to do it by hand: copy both install-<name>.sh and erlite.service to the same directory on each matching node, run the install script there with sudo, then run `./bootstrap-cluster.sh` once every node has erlite.service running.",
			"If tlsMode is generate-self-signed, run `./tls-gen.sh` once before provisioning and distribute its output to the matching nodes.",
		},
	})
	if err != nil {
		return nil, err
	}
	files = append(files, guideFile)

	return files, nil
}
