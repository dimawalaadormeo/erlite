// Package containers generates the Docker/Podman deployment target: a
// compose file usable by either engine, an optional Dockerfile, TLS
// generation, and a bootstrap script that sequences init-cluster/join via
// container exec.
package containers

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

// nodePort pairs a node with the host-side port it publishes. All three
// containers share one Docker host network namespace by default, so they
// cannot all publish the same host port for APIPort -- each gets its own,
// starting at APIPort and counting up, while every container still listens
// on APIPort *inside* its own namespace.
type nodePort struct {
	config.Node
	HostPort int
}

type composeData struct {
	Config       *config.Config
	SeedNodesEnv string
	Nodes        []nodePort
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

// Generate produces the docker/podman target's output for cfg. cfg must
// already have passed config.Validate() for one of those targets.
func Generate(cfg *config.Config) ([]artifact.File, error) {
	seed, ok := cfg.SeedNode()
	if !ok {
		return nil, fmt.Errorf("no seed node found in config (this should have been caught by Validate)")
	}
	others := cfg.OtherNodes()
	seedNodesEnv := strings.Join(cfg.SeedNodesList(), ",")

	nodePorts := make([]nodePort, len(cfg.Nodes))
	for i, n := range cfg.Nodes {
		nodePorts[i] = nodePort{Node: n, HostPort: cfg.APIPort + i}
	}

	var files []artifact.File

	// "docker-compose.yml" is also the filename podman-compose / podman
	// compose expect, so one file serves both targets.
	compose, err := render("docker-compose.yml.tmpl", composeData{Config: cfg, SeedNodesEnv: seedNodesEnv, Nodes: nodePorts})
	if err != nil {
		return nil, err
	}
	files = append(files, artifact.File{Name: "docker-compose.yml", Content: compose, Mode: 0o644})

	if cfg.ImageSource == "build" {
		dockerfile, err := render("Dockerfile.tmpl", cfg)
		if err != nil {
			return nil, err
		}
		files = append(files, artifact.File{Name: "Dockerfile", Content: dockerfile, Mode: 0o644})
	}

	bootstrap, err := render("bootstrap-cluster.sh.tmpl", clusterData{Config: cfg, SeedNode: seed, OtherNodes: others})
	if err != nil {
		return nil, err
	}
	files = append(files, artifact.File{Name: "bootstrap-cluster.sh", Content: bootstrap, Mode: 0o755})

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

	engineLabel := "Docker"
	engineCmd := "docker compose"
	if cfg.Target == config.TargetPodman {
		engineLabel = "Podman"
		engineCmd = "podman-compose (or `podman compose`)"
	}

	guideFile, err := guide.Render(guide.Input{
		Config:      cfg,
		TargetLabel: engineLabel,
		Prerequisites: []string{
			fmt.Sprintf("%s installed on the host that will run these containers", engineLabel),
			fmt.Sprintf("Ports %d-%d free on the host: each node publishes its own port starting at %d (all containers listen on %d internally)", cfg.APIPort, cfg.APIPort+len(cfg.Nodes)-1, cfg.APIPort, cfg.APIPort),
		},
		InstallSteps: []string{
			"Copy this entire output directory to the host that will run the containers.",
			func() string {
				if cfg.ImageSource == "build" {
					return fmt.Sprintf("Run `%s build` (or the plain `docker build .` / `podman build .` equivalent) to build the image from the Dockerfile.", engineCmd)
				}
				return fmt.Sprintf("Ensure the configured image (%s) is pullable from this host.", cfg.ImageRef)
			}(),
			fmt.Sprintf("Run `%s up -d` to start all %d node containers.", engineCmd, len(cfg.Nodes)),
			"Run `./bootstrap-cluster.sh` to initialize the cluster, join every node, and verify readiness.",
		},
	})
	if err != nil {
		return nil, err
	}
	files = append(files, guideFile)

	return files, nil
}
