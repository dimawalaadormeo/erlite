package config

import (
	"strings"
	"testing"
)

func validServerConfig() *Config {
	c := &Config{
		Target:           TargetServer,
		ClusterName:      "test",
		ErliteReleaseRef: "v1.0.0",
		OSFamily:         "debian",
		SSHUser:          "ops",
		Nodes: []Node{
			{Name: "a", Host: "a.example.com"},
			{Name: "b", Host: "b.example.com"},
			{Name: "c", Host: "c.example.com"},
		},
	}
	c.ApplyDefaults()
	return c
}

func TestValidConfigHasNoErrors(t *testing.T) {
	c := validServerConfig()
	if errs := c.Validate(); len(errs) != 0 {
		t.Fatalf("expected no errors, got %v", errs)
	}
}

func TestApplyDefaultsPicksFirstNodeAsSeed(t *testing.T) {
	c := validServerConfig()
	seed, ok := c.SeedNode()
	if !ok {
		t.Fatal("expected a seed node to be picked")
	}
	if seed.Name != "a" {
		t.Fatalf("expected first node to become seed, got %q", seed.Name)
	}
}

func TestApplyDefaultsDoesNotOverrideExplicitSeed(t *testing.T) {
	c := &Config{
		Nodes: []Node{
			{Name: "a", Host: "a.example.com"},
			{Name: "b", Host: "b.example.com", Seed: true},
			{Name: "c", Host: "c.example.com"},
		},
	}
	c.ApplyDefaults()
	seed, ok := c.SeedNode()
	if !ok || seed.Name != "b" {
		t.Fatalf("expected explicit seed \"b\" to be preserved, got %+v (ok=%v)", seed, ok)
	}
}

func TestValidateRejectsFewerThanThreeNodes(t *testing.T) {
	c := validServerConfig()
	c.Nodes = c.Nodes[:2]
	errs := c.Validate()
	if !containsSubstring(errs, "at least 3 nodes") {
		t.Fatalf("expected a node-count error, got %v", errs)
	}
}

func TestValidateRejectsDuplicateNodeNames(t *testing.T) {
	c := validServerConfig()
	c.Nodes[1].Name = c.Nodes[0].Name
	errs := c.Validate()
	if !containsSubstring(errs, "duplicate node name") {
		t.Fatalf("expected a duplicate-name error, got %v", errs)
	}
}

func TestValidateRejectsMultipleSeeds(t *testing.T) {
	c := validServerConfig()
	c.Nodes[1].Seed = true // node 0 is already seed via ApplyDefaults
	errs := c.Validate()
	if !containsSubstring(errs, "exactly one node must be marked") {
		t.Fatalf("expected a multiple-seed error, got %v", errs)
	}
}

func TestValidateRejectsReplicationFactorAboveNodeCount(t *testing.T) {
	c := validServerConfig()
	c.ReplicationFactor = 5
	errs := c.Validate()
	if !containsSubstring(errs, "cannot exceed node count") {
		t.Fatalf("expected a replicationFactor error, got %v", errs)
	}
}

func TestValidateRejectsUnimplementedTarget(t *testing.T) {
	c := validServerConfig()
	c.Target = TargetKubernetes
	c.K8sNamespace = "erlite"
	errs := c.Validate()
	if !containsSubstring(errs, "generator is not implemented yet") {
		t.Fatalf("expected an unimplemented-target error, got %v", errs)
	}
}

func TestValidateRequiresContainerImageSource(t *testing.T) {
	c := validServerConfig()
	c.Target = TargetDocker
	c.OSFamily = ""
	c.SSHUser = ""
	c.ImageSource = "neither-build-nor-pull"
	errs := c.Validate()
	if !containsSubstring(errs, "imageSource must be") {
		t.Fatalf("expected an imageSource error, got %v", errs)
	}
}

func TestValidateRequiresTLSPathsWhenProvideExisting(t *testing.T) {
	c := validServerConfig()
	c.TLSMode = TLSProvideExisting
	errs := c.Validate()
	if !containsSubstring(errs, "tlsCertPath and tlsKeyPath are required") {
		t.Fatalf("expected a TLS path error, got %v", errs)
	}
}

func TestDiskReserveDefaultMatchesErlitePlacementDefault(t *testing.T) {
	c := validServerConfig()
	if c.DiskReserveBytes != 1073741824 {
		t.Fatalf("expected default disk reserve to match erlite_placement's DEFAULT_DISK_RESERVE, got %d", c.DiskReserveBytes)
	}
}

func TestQuorum(t *testing.T) {
	c := validServerConfig()
	c.ReplicationFactor = 3
	if got := c.Quorum(); got != 2 {
		t.Fatalf("expected quorum 2 for RF=3, got %d", got)
	}
}

func containsSubstring(errs []string, substr string) bool {
	for _, e := range errs {
		if strings.Contains(e, substr) {
			return true
		}
	}
	return false
}
