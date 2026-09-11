// Command erlite-deploy is the single generator behind both the erlite-deploy
// GUI and the AI-driven deployment workflow (see tools/erlite-deploy/ai/AI_GUIDE.md).
// Neither front-end hand-writes deployment scripts; both build a config.json
// conforming to internal/config and hand it to this binary.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"erlite-deploy/internal/artifact"
	"erlite-deploy/internal/config"
	"erlite-deploy/internal/generate"
)

const version = "0.1.0"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "validate":
		err = runValidate(os.Args[2:])
	case "generate":
		err = runGenerate(os.Args[2:])
	case "questions":
		err = runQuestions(os.Args[2:])
	case "version":
		fmt.Println(version)
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `erlite-deploy -- generate Erlite cluster deployment scripts and guides

Usage:
  erlite-deploy validate  --config FILE [--json]
  erlite-deploy generate  --config FILE --out DIR [--json]
  erlite-deploy questions [--target TARGET] [--json]
  erlite-deploy version

"validate" and "generate" both apply config defaults and report every
problem found, not just the first. Use --json for machine-readable output
(the form an AI front-end should always use -- see ai/AI_GUIDE.md).
`)
}

func runValidate(args []string) error {
	fs := flag.NewFlagSet("validate", flag.ExitOnError)
	configPath := fs.String("config", "", "path to the config JSON file")
	jsonOut := fs.Bool("json", false, "emit machine-readable JSON output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	errs := cfg.Validate()

	if *jsonOut {
		return printJSON(map[string]any{
			"valid":  len(errs) == 0,
			"errors": errs,
		})
	}
	if len(errs) == 0 {
		fmt.Println("valid")
		return nil
	}
	fmt.Printf("%d problem(s) found:\n", len(errs))
	for _, e := range errs {
		fmt.Println(" -", e)
	}
	os.Exit(1)
	return nil
}

func runGenerate(args []string) error {
	fs := flag.NewFlagSet("generate", flag.ExitOnError)
	configPath := fs.String("config", "", "path to the config JSON file")
	outDir := fs.String("out", "./erlite-deploy-out", "output directory for generated files")
	jsonOut := fs.Bool("json", false, "emit machine-readable JSON output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if errs := cfg.Validate(); len(errs) > 0 {
		if *jsonOut {
			_ = printJSON(map[string]any{"valid": false, "errors": errs})
		} else {
			fmt.Printf("%d problem(s) found, not generating:\n", len(errs))
			for _, e := range errs {
				fmt.Println(" -", e)
			}
		}
		os.Exit(1)
	}

	files, err := generate.Run(cfg)
	if err != nil {
		return err
	}
	if err := artifact.WriteAll(files, *outDir); err != nil {
		return err
	}

	names := make([]string, 0, len(files))
	for _, f := range files {
		names = append(names, f.Name)
	}

	if *jsonOut {
		return printJSON(map[string]any{
			"generated": names,
			"outDir":    *outDir,
		})
	}
	fmt.Printf("generated %d file(s) in %s:\n", len(files), *outDir)
	for _, n := range names {
		fmt.Println(" -", n)
	}
	fmt.Println("\nSee DEPLOY_GUIDE.md in the output directory for install and verification steps.")
	return nil
}

func runQuestions(args []string) error {
	fs := flag.NewFlagSet("questions", flag.ExitOnError)
	target := fs.String("target", "", "filter to questions relevant to this target")
	jsonOut := fs.Bool("json", false, "emit machine-readable JSON output")
	if err := fs.Parse(args); err != nil {
		return err
	}

	var questions []config.Question
	if *target != "" {
		questions = config.QuestionsForTarget(config.Target(*target))
	} else {
		questions = config.Questions()
	}

	if *jsonOut {
		return printJSON(questions)
	}
	for _, q := range questions {
		req := ""
		if q.Required {
			req = " (required)"
		}
		fmt.Printf("- [%s]%s %s\n", q.ID, req, q.Prompt)
		if q.Help != "" {
			fmt.Printf("    %s\n", q.Help)
		}
	}
	return nil
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
