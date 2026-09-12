// Package generate dispatches a validated Config to the right per-target
// generator. Every registered generator shares one contract: []artifact.File
// in, always including a DEPLOY_GUIDE.md, out.
package generate

import (
	"fmt"

	"erlite-deploy/internal/artifact"
	"erlite-deploy/internal/config"
	"erlite-deploy/internal/generators/containers"
	"erlite-deploy/internal/generators/server"
)

type generatorFunc func(*config.Config) ([]artifact.File, error)

var registry = map[config.Target]generatorFunc{
	config.TargetDocker: containers.Generate,
	config.TargetPodman: containers.Generate,
	config.TargetServer: server.Generate,
}

// Run generates every output file for cfg. Callers should run
// cfg.Validate() first; Run returns an error for a target with no
// implemented generator rather than guessing.
func Run(cfg *config.Config) ([]artifact.File, error) {
	fn, ok := registry[cfg.Target]
	if !ok {
		return nil, fmt.Errorf("no generator implemented for target %q", cfg.Target)
	}
	return fn(cfg)
}
