# Erlite User Guide

This guide covers the functionality implemented through Phase 6. Erlite is
currently a development-stage Erlang/OTP runtime for operating many isolated,
Raft-replicated SQLite databases. Phase 7 node expansion and database movement
have not yet been implemented.

## Requirements

- Erlang/OTP 29
- `rebar3`
- POSIX `sync` with `sync -d` support
- Three hosts or Erlang nodes for a production-ready RF=3 cluster
- Shared Erlang distribution cookie and working node-to-node connectivity
- TLS certificate and private key when enabling the HTTP API

## Build and verify

From the repository root:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 escriptize
```

Common Test's distributed suites require a named Erlang node:

```bash
ERL_FLAGS="-sname erlite_test" rebar3 ct
```

The generated command is `_build/default/bin/erlite`.

## Node configuration

Every command requires the following environment variables:

```bash
export ERLITE_STORAGE_PATH=/var/lib/erlite
export ERLITE_NODE_NAME=erlite1@db1.example.net
export ERLITE_CLUSTER_NAME=production
export ERLITE_REPLICATION_FACTOR=3
export ERLITE_SEED_NODES=erlite1@db1.example.net,erlite2@db2.example.net,erlite3@db3.example.net
```

`ERLITE_STORAGE_PATH` must be absolute. `ERLITE_NODE_NAME` must match the
distributed Erlang node name used to start the VM. Node identity and cluster
metadata are persisted below the storage path; do not copy one node's identity
directory to another node.

Start commands with distributed Erlang naming and the cluster cookie configured
for your environment. For example:

```bash
ERL_FLAGS="-name erlite1@db1.example.net -setcookie replace-me" \
  _build/default/bin/erlite init-cluster
```

Keep the cookie secret and use Erlang distribution security appropriate for the
deployment network.

## Create a three-node cluster

On the first node, initialize the cluster:

```bash
_build/default/bin/erlite init-cluster
```

On the second and third nodes, join through an existing catalog member:

```bash
_build/default/bin/erlite join erlite1@db1.example.net
```

Check authoritative catalog status from a configured member:

```bash
_build/default/bin/erlite cluster status
```

The bootstrap catalog begins with one member. It is not production-ready until
three distinct nodes are active. To remove the local node:

```bash
_build/default/bin/erlite leave
```

Do not use node removal as a substitute for Phase 7 replica movement. Before
Phase 7, operators must ensure that removing a node cannot strand database
replicas.

## Enable the HTTPS API

The API is disabled by default and never exposes plaintext HTTP. Configure the
`erlite_core` application before it starts, normally in the deployment's
`sys.config`:

```erlang
[
 {erlite_core,
  [{storage_root, "/var/lib/erlite/databases"},
   {catalog_server, {erlite_catalog, 'erlite1@db1.example.net'}},
   {api,
    #{enabled => true,
      port => 8443,
      certfile => "/etc/erlite/tls/server.crt",
      keyfile => "/etc/erlite/tls/server.key",
      credentials =>
        [#{token => <<"replace-with-at-least-32-random-bytes">>,
           role => admin},
         #{token => <<"replace-with-another-32-byte-secret">>,
           role => service,
           databases => [<<"merchant-100">>]}]}}]}
].
```

Admin credentials can create, list, inspect, and delete databases and can use
all data endpoints. Service credentials can only use data endpoints for their
configured database allow-list. `databases => all` permits all databases but
does not grant control operations. Store tokens outside source control and use
certificates issued by a trusted PKI.

Set these shell variables for the examples below:

```bash
export ERLITE_URL=https://erlite.example.net:8443
export ERLITE_TOKEN=replace-with-admin-token
```

## Database operations

Check service health without authentication:

```bash
curl --fail --cacert /path/to/ca.crt "$ERLITE_URL/v1/health"
```

Create a database with an admin token:

```bash
curl --fail --cacert /path/to/ca.crt \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_id":"merchant-100"}' \
  "$ERLITE_URL/v1/databases"
```

List catalog databases or inspect one database:

```bash
curl --fail --cacert /path/to/ca.crt \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  "$ERLITE_URL/v1/databases"

curl --fail --cacert /path/to/ca.crt \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  "$ERLITE_URL/v1/databases/merchant-100"
```

Delete a database:

```bash
curl --fail --cacert /path/to/ca.crt \
  -X DELETE \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  "$ERLITE_URL/v1/databases/merchant-100"
```

Database IDs in URLs must use standard percent encoding. Deletion is a durable,
catalog-fenced lifecycle operation and leaves an authoritative tombstone.

## Replicated transactions

All application writes go through the transaction endpoint and Raft. Values
are bound parameters, not interpolated SQL:

```bash
curl --fail --cacert /path/to/ca.crt \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "transaction_id":"sale-2026-000001",
    "schema_version":0,
    "statements":[
      {"sql":"INSERT INTO products(sku,name) VALUES(?,?)", "params":["A1","Widget"]}
    ],
    "timeout_ms":15000
  }' \
  "$ERLITE_URL/v1/databases/merchant-100/transactions"
```

Transaction IDs provide idempotency. If a transaction times out, its commit
outcome is ambiguous: retry with exactly the same transaction ID, schema
version, SQL, and parameters. Reusing an ID with different content is rejected.

Only deterministic SQL accepted by Erlite's replicated command policy can be
submitted. Cross-database transactions are not supported.

## Consistent queries

Queries perform a quorum-confirmed Raft barrier, catch the leader's SQLite
replica up to that barrier, and then execute with SQLite read-only enforcement:

```bash
curl --fail --cacert /path/to/ca.crt \
  -H "Authorization: Bearer $ERLITE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "sql":"SELECT name FROM products WHERE sku = ?",
    "params":["A1"],
    "timeout_ms":15000
  }' \
  "$ERLITE_URL/v1/databases/merchant-100/query"
```

The external query interface accepts one `SELECT`, rejects comments and extra
statements, and prevents access to Erlite's internal tables. SQLite
`PRAGMA query_only` provides an additional engine-level mutation guard.

## Limits and errors

- Headers are limited to 16 KiB.
- Request bodies are limited to 1 MiB.
- Operation timeouts must be between 1 and 60,000 milliseconds.
- Each HTTP/1.1 connection serves one request and then closes.
- Malformed framing returns JSON `400`; oversized input returns `413`.
- Authentication failures return `401`; authorization failures return `403`.
- Errors use `{"error": ...}` and successful calls use `{"status":"ok"}` or
  `{"result": ...}`.

## Client examples

- `examples/python/client.py` demonstrates a parameterized consistent query.
- `examples/php/client.php` demonstrates an idempotent replicated transaction.

Replace the example URL and token before use. Both examples verify TLS
certificates and should be configured with the deployment's trusted CA.

## Current project boundary

Phases 0 through 6 are complete. Development is paused before Phase 7. The
current implementation does not yet provide automated node expansion, durable
database movement, automatic replica repair, rebalancing, backup/restore, or
fleet migrations. See `ERLITE_PROJECT.md` for the roadmap and
`docs/correctness.md` for implemented guarantees.
