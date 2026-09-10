# Erlite Deployment System — Plan

Status: proposed, not yet implemented. Written as an implementation-ready spec
so either Claude or Codex can build it without further design discussion.

## 1. Problem

Operators need to stand up an Erlite cluster (minimum 3 servers per
`ERLITE_PROJECT.md` §3) on one of several target environments:

- containers (Docker, Podman, Kubernetes)
- servers/VMs (cloud or bare metal)
- Proxmox (VM or LXC)

Two front-ends should produce this deployment:

1. a **web GUI** that walks through configuration and generates scripts
2. an **AI assistant** that asks the same questions conversationally and
   generates the same scripts

## 2. Core design principle

Build **one** config schema and **one** generator engine. The GUI and the AI
are both just question-askers that produce the same canonical config object
and hand it to the same generator CLI. Neither front-end contains its own
copy of "how to render a docker-compose file" or "how to render a systemd
unit" — that logic lives in exactly one place.

```
                 ┌────────────────────┐
   web wizard →  │                    │
                 │  canonical config  │  →  generator core  →  target artifacts
   AI chat    →  │   (JSON, schema-   │      (templates +         (scripts,
                 │      validated)    │       per-target           manifests,
                 │                    │       modules)              configs)
                 └────────────────────┘
```

If this principle is violated (GUI and AI each independently "know" how to
build a docker-compose file), the two paths will silently diverge as one gets
updated and the other doesn't. Everything below is organized to keep that
from happening.

### Why this matters concretely

- The GUI's backend and the AI's tool-call both end up being: "build a JSON
  object conforming to the schema, then run `erlite-deploy generate`."
- A JSON Schema (generated from the Go config struct) is the single source
  of truth for: what questions exist, their types/defaults/validation rules,
  and their help text. The GUI's `html/template` wizard pages are driven by
  walking that same struct/schema field-by-field; the AI can literally read
  the schema's `description` fields to know what to ask and in what order.

## 3. Canonical config schema (shared question set)

Both front-ends ask the same questions, grouped as follows. Field names below
are suggestions for the actual JSON Schema keys.

**Target selection**
- `target`: `docker` | `podman` | `kubernetes` | `server` | `proxmox_vm` | `proxmox_lxc`

**Cluster topology** (maps to ERLITE_PROJECT.md §3, §5)
- `clusterName`
- `nodeCount` (min 3, default 3)
- `nodes[]`: `{ name, host/IP, role: seed|join }`
- `replicationFactor` (default 3)
- `seedNodes` (derived from `nodes[]`, first node is the default seed)

**Storage**
- `storagePath` (default `/var/lib/erlite`)
- `diskSizeGiB` per node
- `diskReserveBytes` (Phase 12 admission gate — surface it here so operators
  size disks consistently with what the placement policy will enforce)

**Networking**
- `clusterDistPortRange` (Erlang distribution)
- `apiPort` (external HTTP/JSON API)
- `tls`: `generate-self-signed` | `provide-existing` (paths/PEM upload)
- `firewall`: whether to emit firewall rules (ufw/firewalld/security-group)

**Security**
- `adminCredentialSource`: generate | prompt | external secret manager
- `serviceTokens[]`: database allow-lists per service identity (Phase 6)

**Runtime/version pinning** (ERLITE_PROJECT.md §11 — replicas must share a
pinned OTP/SQLite/Erlite build)
- `otpVersion`
- `erliteReleaseRef` (git tag, release tarball URL, or container image tag)
- `sqliteBuildId`

**Resource sizing**
- `cpuPerNode`, `memoryPerNode`

**Observability**
- `metricsScrapeEnabled` (wires `/v1/metrics` into Prometheus-style scraping)
- `logShipping`: none | syslog | file

**Target-specific extensions** (only asked when relevant `target` is chosen)
- *Containers*: `imageSource` (build from Dockerfile vs pull `ref`),
  `registry`, `k8sNamespace`, `k8sStorageClass`, compose vs quadlet (podman)
- *Server/VM*: `osFamily` (debian/rhel/etc.), `sshUser`, `cloudProvider`
  (none/aws/gcp/azure/other — selects cloud-init vs plain script), `initSystem`
  (assume systemd)
- *Proxmox*: `proxmoxApiEndpoint`, `proxmoxNode`, `templateOrImage`,
  `vmOrLxc`, `bridge`, `staticIpOrDhcp`, `coresPerNode`, `ramMiBPerNode`

**Post-deploy behavior**
- `autoBootstrap`: generate scripts only, vs also execute
  `init-cluster`/`join` and poll `/v1/ready`
- `upgradeStrategy`: none | rolling (ties into Phase 13's release-preflight
  compatibility check — emit a pre-upgrade compatibility check step)

## 4. Suggested generated artifacts, per target

Most targets are thin wrappers around a **small shared set of building
blocks** — this is deliberate, so implementation effort isn't duplicated
6 times:

- `install.sh` — idempotent node-local install (fetch/build Erlite, create
  system user, lay out `storagePath`, write config, install systemd unit)
- `erlite.service` — systemd unit template
- `cloud-init.yaml` — user-data template wrapping `install.sh`
- `tls-gen.sh` — self-signed CA + per-node cert generation
- `bootstrap-cluster.sh` — orchestrator that runs `init-cluster` on the seed,
  `join` on the rest, then polls `/v1/ready` on each node
- `sys.config.tpl` / `erlite.env.tpl` — node identity, seed nodes, RF,
  storage path, TLS paths (ERLITE_PROJECT.md §5 config shape)

### Containers — Docker / Podman
- `docker-compose.yml` (or `podman-compose.yml`) with N Erlite services,
  named volumes for `storagePath`, an internal network for cluster
  distribution, environment variables driving `sys.config`
- Podman-specific: optionally emit Quadlet `.container` unit files instead of
  compose, since that's the more "native" Podman systemd-integrated approach
- `Dockerfile` (only if `imageSource = build`), pinning OTP/SQLite versions
  from the config
- `bootstrap-cluster.sh` adapted to `docker exec`/`podman exec`

### Containers — Kubernetes
- A `StatefulSet` (not Deployment — Erlite nodes need stable identity +
  per-node persistent storage, matching "persistent node identity" in
  ERLITE_PROJECT.md §5)
- A headless `Service` for peer discovery/distribution
- `ConfigMap` for cluster config, `Secret` for TLS/admin credentials
- `PersistentVolumeClaim` template per pod (`storageClass` from config)
- Liveness probe → `/v1/health`, readiness probe → `/v1/ready` (these routes
  already exist per Phase 13 observability work)
- `PodDisruptionBudget` capped so voluntary evictions can't take more than
  one member of a 3-node RF group down at once — this is the one place
  Kubernetes' own scheduler needs to be told about Erlite's quorum
  requirement, otherwise a node drain could induce a self-inflicted quorum
  loss
- An init-container or Helm post-install hook sequencing bootstrap (first pod
  `init-cluster`s, the rest `join`)
- Optionally package all of the above as a Helm chart once the plain
  manifests are stable

### Servers / VMs (cloud or bare metal)
- Per-node `install.sh` (the shared building block above)
- `erlite.service` systemd unit
- Bare metal: a plain SSH-fan-out `provision-all.sh` that copies
  `install.sh` to each host and runs it, then runs `bootstrap-cluster.sh`
- Cloud: `cloud-init.yaml` per node (same content as `install.sh`, wrapped
  for cloud-init consumption) — this is intentionally the same artifact
  reused by the Proxmox VM target (§below)
- Optional "advanced" output: minimal Terraform for the 3 VMs themselves
  (out of scope for v1 — flag as a stretch goal, most users will already
  have VM provisioning tooling and just need the node-level scripts)

### Proxmox
- VM mode: reuses the cloud-init artifact from the server/VM target — a
  script using `qm` (or the Proxmox REST API via `curl`) to clone a template,
  attach a cloud-init drive with the generated `cloud-init.yaml`, set
  cores/RAM/disk/bridge/static-IP from config, and start the VM
- LXC mode: a script using `pct create`/`pct exec` to create the container
  and push+run the shared `install.sh` directly (no cloud-init needed for
  LXC)
- A loop wrapper (`provision-all.sh`) that creates all N VMs/LXCs, waits for
  network reachability, then invokes `bootstrap-cluster.sh`

## 5. The AI workflow

The premise is that the "AI" here isn't one product — it's whatever the
operator has: Claude (Code or the app), Codex, Qwen, or anything else. So the
instructions the AI follows must be a plain artifact any model can read, not
something wired into one vendor's tool format.

### 5.1 The model-agnostic instruction artifact: `AI_GUIDE.md`

One plain markdown file, `tools/erlite-deploy/AI_GUIDE.md`, is the single
source of truth for *how the AI should behave* — mirroring the role the JSON
Schema plays for config truth and the generator plays for artifact truth.
It contains:

- The question flow: what to ask, in what order, grouped and gated the same
  way as §3 (skip target-irrelevant questions), with the same defaults and
  validation rules the JSON Schema encodes
- Explicit example dialogue (a short transcript) so a model without strong
  instruction-following still lands on the right shape of conversation
- The exact CLI contract: subcommands, flags, and expected output
- The two operating modes below, and how to detect which one applies
- One hard rule, stated plainly: **never hand-write the deployment scripts
  or manifests from memory.** Always produce a config JSON and either run
  the CLI or tell the user the exact command to run it themselves. This is
  the rule that keeps a model's output from silently drifting away from
  what the GUI would have produced for the same answers — the whole reason
  this system has one generator instead of two.

Any AI is pointed at this file however that tool supports: a Claude Code
skill that just reads and follows `AI_GUIDE.md` (thin wrapper, no logic of
its own), a Codex prompt that says "read AI_GUIDE.md and follow it," or a
user pasting the file's contents as a system/first message for Qwen or any
other chat model. The file itself has no Claude-specific syntax — no
frontmatter, no tool-schema — so it's copy-pasteable anywhere.

### 5.2 Mode 1 — agentic (the AI can run commands)

Applies to Claude Code, Codex CLI, or Qwen behind an agent harness with
shell/tool access.

1. AI interviews the user following `AI_GUIDE.md`'s question flow, applying
   defaults, and explicitly confirming anything security-sensitive
   (credential source, TLS mode) rather than silently assuming.
2. AI writes the answers to `erlite-deploy.config.json`.
3. AI runs `erlite-deploy validate --config erlite-deploy.config.json` — a
   dedicated validate-only subcommand that returns structured errors. This
   exists so the AI gets a clean, parseable round-trip before committing to
   generation, rather than needing to re-implement the schema's validation
   rules itself from reading the description text.
4. On success, AI runs `erlite-deploy generate --config
   erlite-deploy.config.json --target <target> --out <dir>`.
5. The CLI's output always includes `DEPLOY_GUIDE.md` alongside the scripts
   (§5.4) — the AI does not write this itself, it's part of the generator's
   output contract, so guide and scripts can never drift apart.
6. AI presents the file list and a summary. If `autoBootstrap` was
   requested, it may offer to actually run `bootstrap-cluster.sh` /
   `provision-all.sh` — but only with explicit user confirmation first,
   since these provision real servers/VMs and bootstrap a real Raft
   cluster. This matches the general rule that hard-to-reverse,
   infrastructure-affecting actions need a confirmation step, not silent
   execution.

### 5.3 Mode 2 — chat-only (the AI cannot run commands)

Applies to any model used in a plain chat box with no file or shell access
— e.g. Qwen or Claude pasted into a web UI with no tool use.

1. Same question flow as Mode 1, from the same `AI_GUIDE.md`, so a user gets
   an identical interview regardless of which mode they're in.
2. The AI cannot execute `erlite-deploy`, and per the hard rule in §5.1 it
   must not hand-write the scripts itself either. Instead it:
   - Prints the finished `erlite-deploy.config.json` as a code block
   - Gives the user the exact command to run locally:
     `erlite-deploy generate --config erlite-deploy.config.json --target <target>`
   - Tells the user plainly that this requires the `erlite-deploy` binary
     on their machine (linking back to how to get it, since Mode 2 by
     definition can't check or install it for them)
3. This mode is strictly less capable than Mode 1 by design — it produces a
   validated config, not files — which is an acceptable and honest
   limitation of a no-tool-access chat session, rather than a reason to let
   the model improvise scripts.

### 5.4 Generated guides ("how to install on servers")

The generator's output for *every* target includes a `DEPLOY_GUIDE.md`,
rendered from the same config object and template engine as the scripts
themselves — so it names actual hostnames, ports, and paths from this
specific deployment, not generic boilerplate. Structure:

- **Prerequisites** — access needed (SSH/sudo, kubectl context, Proxmox API
  token scope), ports to open (the real port numbers from config), DNS/hosts
  entries, TLS material required up front vs. generated
- **Numbered install steps**, target-specific and sequenced, e.g. for
  server/VM: copy `install.sh` to each of the N named nodes, run it, then
  `erlite init-cluster` on the seed and `erlite join <seed>` on the rest, in
  that order; for Kubernetes: the `kubectl apply` order across
  namespace/configmap/secret/statefulset/service/pdb and how to watch
  rollout status; for Proxmox: token permissions needed, run
  `provision-all.sh`, how to confirm cloud-init finished before bootstrap
- **Verification** — how to confirm the cluster is actually healthy
  afterward: `erlite cluster status` showing N active members, `/v1/ready`
  returning 200 on each node, matching the quorum/health invariants in
  ERLITE_PROJECT.md §13-14
- **Troubleshooting** — the failure modes an operator following this guide
  is most likely to hit: port conflicts, TLS mismatch between nodes,
  placement rejecting a node for insufficient disk (the Phase 12 admission
  gate), a node failing the Phase 13 release-compatibility preflight on join
- **Security follow-ups** — replace self-signed certs before production,
  rotate the generated admin token, tighten the emitted firewall rules
- **Upgrade procedure** — the rolling-upgrade sequence, pointing at Phase
  13's release-preflight compatibility check so an operator upgrades nodes
  one at a time and understands why an incompatible node gets rejected

Both front-ends get this guide identically, since it's generator output, not
something either the GUI or the AI authors separately. The GUI presents it as
a page/download alongside the zip; the AI (Mode 1) surfaces it as a file in
the output directory, or (Mode 2) tells the user it will be produced when
they run the CLI command it gave them.

### 5.5 What's actually AI-specific

Given all of the above is shared, the only real AI-specific value-add is:
in Mode 1, the AI can inspect the *existing* environment before asking
questions — e.g. check whether `kubectl` context or Proxmox API credentials
are already configured, or read existing node hostnames from local SSH
config — and use that to pre-fill defaults or skip questions the answer is
already evident for. It still validates the final object against the same
schema before generating, so an AI-filled config and a human-filled form are
equally valid, equally-checked inputs to the one generator.

## 6. Suggested tech stack

No Node.js, by explicit decision. Chosen on end-user setup simplicity: the
GUI is something an operator downloads and runs on their own machine, not
something they should need a language runtime or package manager to install
first.

- **Core generator + CLI + GUI server: Go, one binary.**
  - Rationale: `go build` produces a single static binary with zero runtime
    dependencies — no Erlang/Elixir install, no Python + pip, no Node/npm.
    Cross-compiling for Linux/macOS/Windows from one machine is trivial
    (`GOOS`/`GOARCH`), so a release is "one file per platform." Go's
    `embed` package bakes HTML templates and static assets directly into
    the binary, so there's nothing to ship alongside it.
  - The same binary serves both roles: `erlite-deploy generate --config
    <file> --target <target>` (the CLI, usable by an AI agent via Bash) and
    `erlite-deploy gui` (spins up a local `net/http` server with the wizard
    UI, opens a browser to `localhost`). One download, both front-ends.
  - Proxmox's API is a plain REST API — callable via `net/http` directly, no
    special client library required.
- **Schema**: a single Go struct (with `jsonschema` struct tags) as the
  canonical config type; generate JSON Schema from it
  (`invopop/jsonschema` or similar) so the GUI can render a form from the
  same source the CLI validates against, and the AI path has one artifact
  to read for question text/defaults/validation rules.
- **Templates**: Go's standard `text/template` (for shell/systemd/cloud-init)
  and `html/template` (for the GUI's own pages). YAML output (Kubernetes
  manifests) should be built via a YAML-object library (e.g. `sigs.k8s.io/yaml`
  or a typed manifest struct marshaled to YAML) rather than hand-templated
  strings, to avoid indentation bugs — render structured data, don't
  string-template YAML.
- **Web GUI**: server-rendered HTML forms (`html/template`) with the wizard
  state kept server-side per session (no SPA, no JS build step); a small
  amount of vanilla JS only where genuinely needed (e.g. dynamic "add
  another node" rows). POSTs the assembled config to the same in-process
  generator and returns a downloadable zip (`archive/zip`, stdlib) plus an
  inline file-by-file preview.
- **AI path**: `erlite-deploy validate` and `erlite-deploy generate` as two
  distinct subcommands (validate returns structured errors without writing
  anything, so an AI can round-trip a config before committing to
  generation), plus the plain-markdown `AI_GUIDE.md` from §5.1 as the
  question-flow contract. Nothing Claude-specific belongs anywhere in this
  path — Qwen, Codex, and Claude all drive the identical binary via the
  identical guide.

## 7. Suggested repo layout

Keep this out of `apps/` — it's tooling *about* Erlite, not part of the
Erlite runtime, so it doesn't need to follow the Erlang app/ADR process in
`CLAUDE.md`. Proposed new top-level directory:

```
tools/erlite-deploy/
├── cmd/erlite-deploy/      # main package: generate/validate/gui subcommands
├── internal/
│   ├── config/             # canonical config struct + JSON Schema export
│   ├── generators/
│   │   ├── docker/
│   │   ├── podman/
│   │   ├── kubernetes/     # typed manifest structs -> YAML, not string templates
│   │   ├── server/         # shared bare-metal + cloud-init logic
│   │   └── proxmox/        # reuses server/ cloud-init + install.sh
│   ├── guide/               # DEPLOY_GUIDE.md renderer (shared by every generator)
│   ├── templates/          # embedded shell/systemd/cloud-init templates
│   └── gui/                # html/template wizard pages + handlers
├── ai/
│   ├── AI_GUIDE.md          # model-agnostic question-flow + behavior contract
│   └── claude-skill/        # thin Claude Code skill that just reads AI_GUIDE.md
└── README.md
```

## 8. Phased build order

Work incrementally, matching this repo's own "don't implement the whole
roadmap in one session" convention:

1. **Schema + CLI skeleton.** Define the config struct/JSON Schema and the
   `erlite-deploy validate` command. No generators yet.
2. **Docker Compose generator + `DEPLOY_GUIDE.md` renderer.** Simplest
   target, fastest feedback loop for validating the
   template/schema/guide approach end-to-end — build the guide renderer here
   so it's a shared building block for every later generator, not bolted on
   at the end.
3. **Server/VM generator** (`install.sh` + `erlite.service` +
   `bootstrap-cluster.sh`), plus its guide content. Highest-value target
   since it directly backs the "basic deployment acceptance test" in
   ERLITE_PROJECT.md §27.
4. **Kubernetes generator**, reusing nothing from Docker Compose except the
   shared config-rendering and guide-rendering helpers — the
   StatefulSet/probe/PDB shape is genuinely different.
5. **Proxmox generator**, reusing the cloud-init and install.sh artifacts
   from step 3 almost unchanged.
6. **Web GUI**, consuming the JSON Schema from step 1 to render its form and
   calling the CLI from steps 2-5.
7. **`AI_GUIDE.md` + thin Claude skill wrapper**, reusing the same
   schema/CLI — write the guide once, then verify by running the same
   config through Mode 1 and through the GUI and diffing the output; they
   must match exactly.
8. **Polish**: `autoBootstrap` execution mode, TLS automation, post-deploy
   health verification against `/v1/ready`, rolling-upgrade compatibility
   pre-check wired to Phase 13's release-preflight semantics.

## 9. Open decisions for the project owner

- Repo placement: this plan assumes a `tools/erlite-deploy/` subdirectory in
  this monorepo. A separate repo is equally workable if you'd rather version
  it independently of Erlite releases — flag before step 1 if so.
- Whether Terraform/IaC output for the VMs themselves (vs. just the
  node-level install) is in scope for v1 (recommendation above: no, stretch
  goal).
- Whether Helm packaging is required for v1 or plain manifests are
  acceptable initially (recommendation: plain manifests first, Helm once
  stable).
