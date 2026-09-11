// Package guide renders DEPLOY_GUIDE.md -- the human-readable runbook every
// generator produces alongside its scripts/manifests. It is rendered from
// the same Config and the same template engine as the scripts themselves, so
// it names real hostnames/ports/paths from this deployment rather than being
// generic boilerplate, and it can never drift from what the scripts actually
// do since generators supply their own install-step text directly.
package guide

import (
	"bytes"
	"embed"
	"fmt"
	"text/template"

	"erlite-deploy/internal/artifact"
	"erlite-deploy/internal/config"
)

//go:embed templates/DEPLOY_GUIDE.md.tmpl
var templateFS embed.FS

// Input is what a generator supplies about its own target on top of the
// shared config; the generic Verification/Troubleshooting/Security/Upgrade
// content is baked into the template and always included.
type Input struct {
	Config          *config.Config
	TargetLabel     string
	Prerequisites   []string
	InstallSteps    []string
	Verification    []string
	Troubleshooting []string
	SecurityNotes   []string
}

type renderData struct {
	Input
	Quorum int
}

var funcs = template.FuncMap{
	"inc": func(i int) int { return i + 1 },
}

// Render produces the DEPLOY_GUIDE.md file for in.
func Render(in Input) (artifact.File, error) {
	tmpl, err := template.New("DEPLOY_GUIDE.md.tmpl").Funcs(funcs).ParseFS(templateFS, "templates/DEPLOY_GUIDE.md.tmpl")
	if err != nil {
		return artifact.File{}, fmt.Errorf("parsing guide template: %w", err)
	}
	data := renderData{Input: in, Quorum: in.Config.Quorum()}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return artifact.File{}, fmt.Errorf("rendering guide: %w", err)
	}
	return artifact.File{Name: "DEPLOY_GUIDE.md", Content: buf.Bytes(), Mode: 0o644}, nil
}
