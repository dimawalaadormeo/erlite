// Package artifact defines the common output-file type every generator
// produces, and the logic to write a set of them to disk. Keeping this
// separate from the generators and from the config package avoids an import
// cycle between "generators produce guide.Render output" and "guide needs to
// know the file type."
package artifact

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// File is one generated output file, relative to the requested output
// directory.
type File struct {
	Name    string
	Content []byte
	Mode    os.FileMode
}

// WriteAll writes every file under dir, creating parent directories as
// needed. It does not remove pre-existing files in dir first: regenerating
// into the same directory overwrites files this tool produces but leaves
// anything else the operator put there alone.
func WriteAll(files []File, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating output directory %s: %w", dir, err)
	}
	for _, f := range files {
		if f.Name == "" || f.Name == ".." || filepath.IsAbs(f.Name) ||
			filepath.Clean(f.Name) != f.Name || strings.HasPrefix(f.Name, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe artifact path %q", f.Name)
		}
		path := filepath.Join(dir, f.Name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("creating directory for %s: %w", f.Name, err)
		}
		mode := f.Mode
		if mode == 0 {
			mode = 0o644
		}
		if err := os.WriteFile(path, f.Content, mode); err != nil {
			return fmt.Errorf("writing %s: %w", f.Name, err)
		}
	}
	return nil
}

// ScriptMode returns the executable file mode for shell scripts and the
// default read/write mode for everything else, so generators don't each
// re-decide which of their outputs need +x.
func ScriptMode(name string) os.FileMode {
	if strings.HasSuffix(name, ".sh") {
		return 0o755
	}
	return 0o644
}
