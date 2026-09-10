# Erlite

Erlite is an Erlang/OTP runtime for operating many independently replicated
SQLite databases across a cluster. Each database is an independent RabbitMQ
`ra` group backed by SQLite, allowing capacity to grow by placing and moving
databases across Erlite nodes.

Development follows the phased plan in
[`ERLITE_PROJECT.md`](ERLITE_PROJECT.md). Phases 0 through 13 are complete; the
next roadmap item is scale validation.

## Current capabilities

- Persistent node identity and a three-member replicated cluster catalog
- RF=3 database creation, listing, status, deletion, and restart reconciliation
- Quorum-ordered writes and consistent reads with durable SQLite applied indexes
- Leader election, follower catch-up, idempotent transactions, and quorum-loss
  write refusal
- TLS-only HTTP/JSON access with bearer authentication and database-scoped
  authorization
- Durable, resumable database movement during node expansion
- Automatic under-replication detection and repair after a configurable grace
  period
- Verified replacement bootstrap before failed-member removal
- Quarantine and cleanup of stale replicas when failed nodes return
- Verified backups, portable exports, fenced replacement restore, and cloning
  into an independent Raft history
- Resource-aware placement, leader balancing, and placement groups
- Fleet migrations with canaries, bounded batches, durable pause, and retries
- Join-time rolling-upgrade compatibility checks for protocol, durable formats,
  and SQLite runtime identity
- Liveness, quorum-backed readiness, and bounded operational metrics

Erlite scales across independent databases. It does not make one SQLite
database horizontally multi-writer, provide cross-database transactions, or
act as a general-purpose distributed SQL engine.

## Correctness model

The Raft log is authoritative for write order. SQLite replicas durably record
the Raft index they have applied, and a replacement is not considered ready
until its Ra state and SQLite state have caught up and been verified. Movement
repair, and restore are serialized per database and recorded in the catalog so
they can resume after interruption.

Disk-full and other resource failures do not advance a replica's durable
applied index. Deterministic transaction and migration failures are durably
recorded as failed no-ops while allowing later Raft entries to apply. Failed
migrations leave schema version unchanged and pause the fleet canary.

See [`docs/correctness.md`](docs/correctness.md) and
[`docs/architecture.md`](docs/architecture.md) for the detailed invariants.
The Phase 13 failure matrix is in [`docs/hardening.md`](docs/hardening.md).

## Getting started

Build the release command:

```bash
rebar3 compile
rebar3 escriptize
```

The generated `erlite` command supports:

```text
erlite init-cluster
erlite join <seed-node>
erlite leave
erlite cluster status
```

A production deployment requires three Erlite nodes with compatible Erlang
distribution names and cookies. Setup, database operations, movement, and API
examples are in [`docs/user-guide.md`](docs/user-guide.md).

## Automatic repair

Automatic repair is supervised and enabled by default. Its timing can be set
in the `erlite_core` application environment:

```erlang
{repair_grace_period_ms, 30000},
{repair_scan_interval_ms, 5000}
```

When exactly one RF=3 member fails, Erlite waits for the grace period and then
uses a surviving replica to bootstrap an eligible active node. The failed
member is removed only after the replacement catches up and verifies. If no
safe target exists—or fewer than two replicas are healthy—the repair remains
pending without reducing membership.

The accepted movement and repair protocols are documented in
[`docs/adr/0001-durable-database-movement.md`](docs/adr/0001-durable-database-movement.md)
and
[`docs/adr/0002-automatic-replica-repair.md`](docs/adr/0002-automatic-replica-repair.md).

## Automatic rebalancing

The catalog leader incrementally balances ready replicas across healthy active
nodes. Each scan selects at most one sequential migration by default and runs
it through the durable movement protocol. Databases already moving or repairing
are excluded. The decision is documented in
[`docs/adr/0003-automatic-rebalancing.md`](docs/adr/0003-automatic-rebalancing.md).

## Backup and restore

Backup creation first establishes a quorum barrier and catches up the selected
SQLite replica. The resulting manifest records the database identity, placement
generation, applied Raft index and term, schema and SQLite runtime versions,
creation time, and SHA-256 checksum. Erlite verifies the image and its internal
applied index before reporting success.

The Erlang lifecycle API provides the Phase 10 operations:

```erlang
{ok, Backup} = erlite_database_lifecycle:backup(<<"merchant-100">>),
ok = erlite_database_lifecycle:export(Backup, "/srv/backups/merchant-100.erlite"),

%% Create a different database with independent placement and Raft history.
ok = erlite_database_lifecycle:clone(<<"merchant-100-copy">>, Backup),

%% Explicitly replace the existing database with the backed-up state.
ok = erlite_database_lifecycle:restore(<<"merchant-100">>, Backup).
```

Replacement restore advances the database generation and uses a durable,
operation-ID-fenced `restoring` catalog state. The catalog rejects replacement
from a backup belonging to a different database. Clone is the explicit
cross-database operation and begins at generation one under a new database ID.
In both modes, Erlite preserves application data but
resets the imported image's applied-index and transaction ledger before starting
a new Raft group. A backup image is therefore never attached to an incompatible
live Raft history. Corrupt images and exports fail checksum verification.

The backup source referenced by `Backup` must remain reachable until restore or
clone completes; exporting produces a durable portable artifact. The accepted
protocol is documented in
[`docs/adr/0004-fenced-backup-restore.md`](docs/adr/0004-fenced-backup-restore.md).

## Health and metrics

`GET /v1/health` is an unauthenticated process-liveness check. `GET /v1/ready`
also requires no token and returns `200` only when the required workers are up
and a consistent catalog query confirms three active catalog members. Admins
can inspect bounded counters, VM pressure, and aggregate database resource
measurements at `GET /v1/metrics`.

Before joining, a node compares cluster protocol ranges, command and snapshot
formats, and SQLite runtime identity with the seed. Incompatible releases fail
before local cluster metadata or catalog membership is changed.

## License

Erlite is licensed under the [Apache License 2.0](LICENSE). Dependency license
details are recorded in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Requirements

- Erlang/OTP 29
- rebar3
- a POSIX `sync` utility supporting `sync -d` for durable checkpoint publication

## Development

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 escriptize
```

The optional TLS HTTP/JSON service is documented in
[`docs/http-api.md`](docs/http-api.md), with Python and PHP clients under
[`examples/`](examples/).
