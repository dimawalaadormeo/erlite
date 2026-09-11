# erlite-deploy

Generates Erlite cluster deployment scripts, manifests, and a tailored
install guide from one config file. Single static Go binary, no runtime
dependencies. See `../../docs/deployment-system-plan.md` for the full design.

## Build

```
go build -o erlite-deploy ./cmd/erlite-deploy
```

## Usage

```
erlite-deploy questions [--target TARGET] [--json]   # what to ask, and in what order
erlite-deploy validate  --config FILE [--json]        # check a config, report every problem
erlite-deploy generate  --config FILE --out DIR [--json]
```

A minimal config for the `server` target:

```json
{
  "target": "server",
  "clusterName": "production",
  "nodes": [
    {"name": "erlite-a", "host": "server-a.example.com", "seed": true},
    {"name": "erlite-b", "host": "server-b.example.com"},
    {"name": "erlite-c", "host": "server-c.example.com"}
  ],
  "erliteReleaseRef": "v1.0.0",
  "osFamily": "debian",
  "sshUser": "ops"
}
```

```
erlite-deploy generate --config config.json --out ./out
```

produces `install-<node>.sh` per node, `erlite.service`,
`bootstrap-cluster.sh`, `provision-all.sh`, `tls-gen.sh` (if
`tlsMode` is `generate-self-signed`), `admin-credentials.txt` (if
`adminCredentialSource` is `generate`), and `DEPLOY_GUIDE.md`.

For the `docker` / `podman` target, the required fields are `target`,
`clusterName`, `nodes`, and `erliteReleaseRef`; output is
`docker-compose.yml` (works with either engine), a `Dockerfile` if
`imageSource` is `build`, `bootstrap-cluster.sh`, and the same TLS/admin/guide
files.

## Status

Implemented: `docker`, `podman`, `server` targets; `validate`/`generate`/
`questions` CLI; the config schema; the shared `DEPLOY_GUIDE.md` renderer.

Not yet implemented (defined in the schema, rejected by `validate` with an
explicit "not implemented yet" error): `kubernetes`, `proxmox_vm`,
`proxmox_lxc`. Also not yet built: the web GUI, `autoBootstrap` execution,
and Terraform/Helm output. See the phased build order in
`../../docs/deployment-system-plan.md`.

## AI front-end

`ai/AI_GUIDE.md` is the model-agnostic instruction set for any AI helping a
user through a deployment -- point Claude, Codex, Qwen, or anything else at
it. `ai/claude-skill/` is a thin Claude Code skill wrapper that just reads
it; there is nothing Claude-specific in the guide itself.
