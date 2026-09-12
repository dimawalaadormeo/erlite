# Deploying Erlite

This tutorial describes two ways to deploy a three-node Erlite cluster:

1. generate Docker, Podman, or server artifacts with `erlite-deploy`; or
2. configure and bootstrap three servers manually.

Erlite's minimum production topology is three nodes. Each database normally
has three replicas, consistent operations require a quorum of two, and service
readiness requires all three catalog members to be active.

## Current packaging limitation

The repository currently builds and tests the Erlite applications and the
`erlite` escript, but it does not yet contain a complete `relx` production
release definition. Generated server artifacts expect an operational release
at `/opt/erlite/bin/erlite` with a long-running `foreground` command. The
generated container Dockerfile assumes the same release exists after
`rebar3 as prod release`.

Before using either production workflow, provide a release package or image
that supplies that runtime contract. The generated server installer marks the
exact release-installation location with a `TODO` and stops rather than
pretending installation succeeded. Until release packaging is added, use these
instructions as the deployment and bootstrap contract, not as a claim that a
source checkout is a turnkey production package.

## Plan the cluster

The examples use these nodes:

| Node | Erlang node name | Host |
| --- | --- | --- |
| Seed | `erlite-a@db-a.example.com` | `db-a.example.com` |
| Node B | `erlite-b@db-b.example.com` | `db-b.example.com` |
| Node C | `erlite-c@db-c.example.com` | `db-c.example.com` |

Prepare the following before installation:

- forward and reverse DNS, or stable host mappings, for every node;
- one identical, securely distributed Erlang cookie;
- a dedicated data volume on every host;
- TCP 4369 and the configured Erlang distribution range between nodes;
- the HTTPS API port from trusted clients or load balancers;
- synchronized clocks and a common trusted CA; and
- a compatible Erlang/OTP, Erlite, SQLite, and NIF build on every node.

Do not expose Erlang distribution ports to the public internet. Restrict them
to the cluster network with host and network firewalls.

## Option A: deploy with `erlite-deploy`

### 1. Build the generator

From the repository root:

```bash
cd tools/erlite-deploy
go test ./...
go build -o erlite-deploy ./cmd/erlite-deploy
```

Inspect the available questions if you are building configuration through an
automation agent or another frontend:

```bash
./erlite-deploy questions --target server
./erlite-deploy questions --target docker --json
```

The implemented targets are `server`, `docker`, and `podman`. Kubernetes and
Proxmox values exist in the schema but are rejected until their generators are
implemented.

### 2. Server or VM deployment

Create `server-config.json`:

```json
{
  "target": "server",
  "clusterName": "production",
  "nodes": [
    {"name": "erlite-a", "host": "db-a.example.com", "seed": true},
    {"name": "erlite-b", "host": "db-b.example.com"},
    {"name": "erlite-c", "host": "db-c.example.com"}
  ],
  "replicationFactor": 3,
  "storagePath": "/var/lib/erlite",
  "clusterDistPortRange": "9100-9105",
  "apiPort": 4433,
  "tlsMode": "generate-self-signed",
  "firewall": true,
  "adminCredentialSource": "generate",
  "otpVersion": "29.0.3",
  "erliteReleaseRef": "v1.0.0",
  "osFamily": "debian",
  "sshUser": "ops"
}
```

Node names, hosts, cluster names, SSH users, and storage paths are deliberately
restricted to shell-safe forms. Server nodes must use distinct hosts because
two generated installs on the same host would overwrite the same service and
data configuration.

Validate before generating anything:

```bash
./erlite-deploy validate --config server-config.json
./erlite-deploy validate --config server-config.json --json
```

Both forms exit nonzero when configuration is invalid. Generate the artifacts:

```bash
./erlite-deploy generate \
  --config server-config.json \
  --out ./server-deployment
```

The output contains:

- one `install-<node>.sh` per host;
- `erlite.service`, required beside each install script;
- `provision-all.sh` and `bootstrap-cluster.sh`;
- `tls-gen.sh` when self-signed TLS was requested;
- `admin-credentials.txt` when credential generation was requested; and
- a deployment-specific `DEPLOY_GUIDE.md`.

Review every generated file. In particular, integrate your package, registry,
or tarball installation into the marked release-installation section so that
`/opt/erlite/bin/erlite foreground` is available.

For a self-signed test deployment, generate TLS material once:

```bash
cd server-deployment
./tls-gen.sh ./tls
```

Distribute each node's certificate and key plus the shared CA through your
secret-management system. Self-signed material is suitable for an isolated
test environment; use certificates from your organizational CA in production.

To provision through SSH after the release and TLS integration has been
reviewed:

```bash
./provision-all.sh
```

For manual control, copy both the matching install script and
`erlite.service` to each host, run the install script with `sudo`, start the
services, and then run `bootstrap-cluster.sh` from the operator machine.

### 3. Docker or Podman deployment

Use a prebuilt operational release image when available. For example:

```json
{
  "target": "docker",
  "clusterName": "development",
  "nodes": [
    {"name": "erlite-a", "host": "db-a.example.com", "seed": true},
    {"name": "erlite-b", "host": "db-b.example.com"},
    {"name": "erlite-c", "host": "db-c.example.com"}
  ],
  "storagePath": "/var/lib/erlite",
  "apiPort": 4433,
  "tlsMode": "generate-self-signed",
  "imageSource": "pull",
  "imageRef": "registry.example.com/erlite:v1.0.0",
  "erliteReleaseRef": "v1.0.0"
}
```

Validate and generate:

```bash
./erlite-deploy validate --config container-config.json
./erlite-deploy generate \
  --config container-config.json \
  --out ./container-deployment
cd container-deployment
```

Inspect `docker-compose.yml` and generate or provide TLS material. Before
starting, ensure the image's release configuration mounts those files and
enables the TLS API; certificate generation alone does not configure the
runtime. Then start and bootstrap the containers:

```bash
./tls-gen.sh ./tls
docker compose up -d
docker compose ps
./bootstrap-cluster.sh
```

For Podman, set `target` to `podman`, use `podman compose` or
`podman-compose`, and tell the bootstrap script which engine to use:

```bash
podman compose up -d
ERLITE_CONTAINER_ENGINE=podman ./bootstrap-cluster.sh
```

Each container listens on the configured API port internally. The generated
compose file publishes consecutive host ports beginning at that value, so a
three-node configuration using 4433 publishes 4433, 4434, and 4435.

If `imageSource` is `build`, the generated Dockerfile expects a working `prod`
release profile. Add the missing production release definition before using
that path.

## Option B: deploy manually

Manual deployment uses the same invariants as the generator and is useful when
configuration management already handles packages, services, certificates,
and secrets.

### 1. Install the same release everywhere

Install a pinned release under `/opt/erlite` on all three hosts. Verify:

```bash
/opt/erlite/bin/erlite versions
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
```

Do not mix arbitrary SQLite/NIF builds. Erlite compares complete SQLite runtime
identity during join and replica readiness, and rejects incompatible members.

### 2. Create storage and service ownership

On every host:

```bash
sudo useradd --system --home /var/lib/erlite --shell /usr/sbin/nologin erlite
sudo install -d -o erlite -g erlite -m 0750 \
  /var/lib/erlite/node \
  /var/lib/erlite/catalog \
  /var/lib/erlite/databases \
  /var/lib/erlite/raft \
  /var/lib/erlite/snapshots \
  /var/lib/erlite/backups
```

Run the command idempotently through configuration management if the user may
already exist.

### 3. Configure each node

Set these values in the service environment on `db-a`:

```text
ERLITE_STORAGE_PATH=/var/lib/erlite
ERLITE_NODE_NAME=erlite-a@db-a.example.com
ERLITE_CLUSTER_NAME=production
ERLITE_REPLICATION_FACTOR=3
ERLITE_SEED_NODES=erlite-a@db-a.example.com,erlite-b@db-b.example.com,erlite-c@db-c.example.com
```

Use the same values on the other hosts except for `ERLITE_NODE_NAME`. The
runtime's actual distributed Erlang name must exactly match that value. Supply
the same cookie securely to every service; do not commit it to source control
or place it in a world-readable environment file.

Configure the distribution listener to use the planned range, then allow TCP
4369 and 9100-9105 only between the three hosts. Configure the TLS-only API in
the release's `sys.config` as described in the
[HTTP API guide](http-api.md), using a node certificate with a valid SAN and a
protected private key.

### 4. Start and bootstrap

Start the long-running Erlite service on all nodes. Using the release's
supported control-command mechanism, initialize only the seed:

```bash
/opt/erlite/bin/erlite init-cluster
```

Then join nodes B and C through the complete seed node name:

```bash
/opt/erlite/bin/erlite join erlite-a@db-a.example.com
```

Never run `init-cluster` independently on all three nodes; that creates three
unrelated cluster identities. Persistent identity beneath
`/var/lib/erlite/node` must not be copied between hosts.

### 5. Verify before accepting traffic

Check authoritative catalog state:

```bash
/opt/erlite/bin/erlite cluster status
```

The result must show all three nodes active. Then verify every API endpoint
using the CA rather than disabling certificate verification:

```bash
curl --fail --cacert /etc/erlite/tls/ca.crt \
  https://db-a.example.com:4433/v1/health
curl --fail --cacert /etc/erlite/tls/ca.crt \
  https://db-a.example.com:4433/v1/ready
```

Repeat readiness against every node. A `503` is not successful deployment: it
means a required worker is down, the consistent catalog query failed, or fewer
than three catalog members are active.

Create a disposable database through the authenticated API, perform a write
and consistent read, and remove it. Examples are in the
[user guide](user-guide.md). Finally, stop one follower and confirm quorum
writes continue, restore it and verify catch-up, then test quorum loss in a
controlled maintenance window and confirm consistent writes are refused.

## Operations checklist

Before declaring the deployment complete:

- all three catalog members are active and `/v1/ready` returns 200 everywhere;
- persistent storage is mounted and survives a service restart;
- certificates validate normally and private keys have restricted permissions;
- the Erlang cookie is identical across nodes and stored securely;
- distribution and API firewall rules are limited to intended networks;
- backup/export storage is separate from live database storage;
- monitoring alerts on readiness, disk reserve, repair, and quorum loss; and
- restore, follower restart, and node-replacement procedures have been tested.

For protocol details and failure guarantees, read
[the correctness model](correctness.md). For deployment-generator internals
and future targets, read [the deployment system plan](deployment-system-plan.md).
