package generate

import (
	"strings"
	"testing"

	"erlite-deploy/internal/config"
)

func baseNodes() []config.Node {
	return []config.Node{
		{Name: "a", Host: "a.example.com"},
		{Name: "b", Host: "b.example.com"},
		{Name: "c", Host: "c.example.com"},
	}
}

func TestRunServerGeneratesGuideAndExpectedFiles(t *testing.T) {
	c := &config.Config{
		Target:           config.TargetServer,
		ClusterName:      "test",
		ErliteReleaseRef: "v1.0.0",
		OSFamily:         "debian",
		SSHUser:          "ops",
		Nodes:            baseNodes(),
	}
	c.ApplyDefaults()
	if errs := c.Validate(); len(errs) != 0 {
		t.Fatalf("config should be valid, got %v", errs)
	}

	files, err := Run(c)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	want := map[string]bool{
		"install-a.sh": false, "install-b.sh": false, "install-c.sh": false,
		"erlite.service": false, "bootstrap-cluster.sh": false,
		"provision-all.sh": false, "tls-gen.sh": false,
		"admin-credentials.txt": false, "DEPLOY_GUIDE.md": false,
	}
	for _, f := range files {
		if _, ok := want[f.Name]; ok {
			want[f.Name] = true
		}
		if len(f.Content) == 0 {
			t.Errorf("file %s has empty content", f.Name)
		}
	}
	for name, found := range want {
		if !found {
			t.Errorf("expected generated file %s not present", name)
		}
	}
}

func TestRunDockerGeneratesGuideAndExpectedFiles(t *testing.T) {
	c := &config.Config{
		Target:           config.TargetDocker,
		ClusterName:      "test",
		ErliteReleaseRef: "v1.0.0",
		Nodes:            baseNodes(),
	}
	c.ApplyDefaults()
	if errs := c.Validate(); len(errs) != 0 {
		t.Fatalf("config should be valid, got %v", errs)
	}

	files, err := Run(c)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	want := map[string]bool{
		"docker-compose.yml": false, "Dockerfile": false,
		"bootstrap-cluster.sh": false, "tls-gen.sh": false,
		"admin-credentials.txt": false, "DEPLOY_GUIDE.md": false,
	}
	for _, f := range files {
		if _, ok := want[f.Name]; ok {
			want[f.Name] = true
		}
		if f.Name == "docker-compose.yml" {
			body := string(f.Content)
			if !strings.Contains(body, `ERLITE_NODE_NAME: "a@a"`) ||
				!strings.Contains(body, `ERLITE_SEED_NODES: "a@a,b@b,c@c"`) {
				t.Errorf("container node identities are inconsistent:\n%s", body)
			}
		}
		if f.Name == "bootstrap-cluster.sh" &&
			!strings.Contains(string(f.Content), "erlite join a@a") {
			t.Errorf("bootstrap join does not use a distributed node name:\n%s", f.Content)
		}
		if f.Name == "tls-gen.sh" &&
			!strings.Contains(string(f.Content), "subjectAltName=") {
			t.Error("generated certificates are missing SAN extensions")
		}
	}
	for name, found := range want {
		if !found {
			t.Errorf("expected generated file %s not present", name)
		}
	}
}

func TestRunRejectsUnimplementedTarget(t *testing.T) {
	c := &config.Config{Target: config.TargetKubernetes}
	if _, err := Run(c); err == nil {
		t.Fatal("expected an error for an unimplemented target")
	}
}
