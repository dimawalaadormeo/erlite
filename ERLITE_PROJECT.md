# Erlite Project Plan

## 1. Project definition

Erlite is a distributed runtime for hosting large numbers of small, isolated SQLite databases across an Erlang/OTP cluster.

Its primary scaling dimension is:

**number of databases / tenants**

not:

**throughput of one enormous database**

Typical applications include:

- multi-tenant POS SaaS
- clinic SaaS
- ERP systems
- database-per-customer applications
- database-per-workspace applications
- branch or site databases
- edge/local databases
- database-as-a-service platforms
- applications requiring thousands of isolated relational databases

Erlite is written in Erlang/OTP but must eventually be usable by applications written in Erlang, Elixir, PHP, Python, Java, Go, Node.js, .NET, and other languages through a network API.

## 2. Core product proposition

Erlite provides isolated SQLite databases that can be created, replicated, placed, moved, backed up, restored, migrated, repaired, and automatically failed over across a cluster.

The application handles users, login, authentication, business logic, billing, and application authorization.

Erlite handles databases, database placement, database replication, consensus, failover, lifecycle, backup, restore, migration, cluster membership, repair, and horizontal scale-out.

The fundamental Erlite object is a `DatabaseId`.

Do not hard-code "tenant" as the storage abstraction.

Examples:

- `merchant-123`
- `clinic-847`
- `workspace-42`
- `project-521`
- `branch-19`

Applications decide what those IDs mean.

## 3. Basic deployment model

The minimum production Erlite deployment is 3 servers.

Example nodes:

- `erlite@server-a`
- `erlite@server-b`
- `erlite@server-c`

Default replication factor: `3`

Default quorum: `2 of 3`

Every database initially has one replica on every server.

Each database has its own Raft group.

The catalog also has its own three-member Raft group.

## 4. Basic cluster bootstrap UX

First server:

```bash
erlite init-cluster
```

Additional servers:

```bash
erlite join server-a
```

Cluster inspection:

```bash
erlite cluster status
```

Node inspection:

```bash
erlite node status server-a
```

Database inspection:

```bash
erlite database status merchant-100
```

This operational UX is a basic Erlite feature, not optional future polish.

## 5. Node configuration

Each Erlite node must have persistent identity.

Example:

```text
node_name = erlite@server-a
cluster_name = production
storage_path = /var/lib/erlite
replication_factor = 3

seed_nodes =
    erlite@server-a
    erlite@server-b
    erlite@server-c
```

Configuration should support environment-variable overrides for container deployment.

Node identity must remain stable across restarts.

## 6. Storage layout

Example:

```text
/var/lib/erlite/
    node/
    catalog/
    databases/
    raft/
    snapshots/
    backups/
```

Per-database files might look like:

```text
/var/lib/erlite/databases/
    merchant-100.sqlite
    merchant-101.sqlite
    merchant-102.sqlite
```

Unsafe characters should never be blindly converted into filesystem paths.

## 7. Core architecture

```text
                     Clients
                        |
                        v
                 Erlite Gateway
                        |
                        v
                   DB Router
                        |
                        v
                Cluster Catalog
                        |
      +-----------------+-----------------+
      |                 |                 |
      v                 v                 v
   Node A            Node B            Node C
      |                 |                 |
SQLite replicas    SQLite replicas   SQLite replicas
```

Each logical database has:

- Database ID
- SQLite database
- Raft group
- replica-set metadata

## 8. Technology choices

Initial implementation:

- Language: Erlang
- Runtime: supported OTP version pinned by project
- Build: rebar3
- Consensus: RabbitMQ `ra`
- SQL engine: SQLite
- SQLite adapter: pluggable Erlang behaviour
- Initial NIF: `esqlite` or equivalent
- Testing: EUnit + Common Test
- Property tests: PropEr where useful

Do not implement Raft.

Do not use `riak_core` in version 1.

Do not implement distributed transactions between databases.

Do not implement PostgreSQL wire compatibility initially.

Do not couple Erlite directly to one SQLite NIF library.

## 9. Fundamental correctness model

The Raft log is the authoritative ordering of writes.

SQLite is the materialized local database representation of committed Raft state.

Every SQLite replica must maintain a durable applied index.

Whenever practical, applying a database transaction and updating `last_applied_raft_index` must happen inside one SQLite transaction.

Reapplying an already-applied Raft index must be harmless.

Replication must not rely solely on asynchronous side effects.

Raft log compaction must never make an unapplied committed command unrecoverable.

Each installable database snapshot must bind together:

- the SQLite database image
- the corresponding Raft index and term
- the schema version
- the database identity and placement generation
- an integrity checksum

A replica whose durable applied index is older than the retained Raft log must install and verify a compatible snapshot before replaying later entries. Raft log entries may be compacted only when the system retains a verified recovery path for every active replica. Snapshot installation must use a temporary file and an atomic activation step; a partially installed snapshot must never be served.

## 10. Write protocol

Initial replicated command representation:

```text
{
    transaction,
    TransactionId,
    SchemaVersion,
    [
        {Sql1, Params1},
        {Sql2, Params2},
        ...
    ]
}
```

The leader returns successful write confirmation only after:

1. Raft has committed the command.
2. The leader's SQLite replica has applied through that committed index.

Followers may apply afterward.

## 11. Write determinism

Version 1 must not assume arbitrary SQLite SQL is deterministic.

Potential examples:

```text
random()
CURRENT_TIMESTAMP
datetime('now')
```

Values such as timestamps, UUIDs, random numbers, and server-generated defaults should be resolved before entering the replicated command whenever required.

Version 1 must define and enforce a replicated-SQL policy. It must reject or normalize operations whose results can vary between replicas, including unsupported uses of:

- time, randomness, and environment-dependent functions
- unordered row selection where the selected rows affect a write
- host-specific collations or user-defined functions
- `ATTACH`, extension loading, and filesystem-affecting PRAGMAs
- SQLite features that differ across the supported SQLite build

All replicas in a group must use a compatible, pinned SQLite version, compile options, collation set, and Erlite schema/runtime version. Triggers, generated columns, defaults, and migration SQL are subject to the same determinism rules.

Transaction requests must have configurable limits for statement count, encoded size, parameter count, execution time, and returned data. The API contract must explicitly define support for DDL, `RETURNING`, result-producing statements, and retry behavior.

Erlite must support detecting replica divergence using metadata and/or state checksums at defined verification points. A divergent replica must not be considered ready and must be repaired from a verified snapshot or another documented recovery source.

## 12. Read modes

Consistent:

```erlang
erlite:query(DatabaseId, Sql, Params, consistent).
```

Local:

```erlang
erlite:query(DatabaseId, Sql, Params, local).
```

Local reads may be slightly stale.

`consistent` means a linearizable read. It must:

1. be authorized by the current Raft leader using a Raft read barrier/read-index mechanism;
2. obtain an index that includes all writes committed before that barrier;
3. wait until the serving SQLite replica has applied through that index; and
4. fail or retry safely if leadership changes before the read is served.

A newly elected leader must not serve consistent reads or acknowledge writes until its SQLite replica is applied through the required committed index. The API must expose timeout and quorum-loss errors rather than silently degrading a consistent read to a local read.

`local` reads may be served only by a ready local replica and should return or expose the replica's applied index so callers can reason about staleness when needed.

## 13. Basic failure behavior

All three healthy:

`A ✓  B ✓  C ✓`

Writes and reads are allowed.

One follower fails:

`A ✓  B ✓  C ✕`

Quorum remains 2/3 and writes continue.

When the failed node returns:

```text
rejoin
  ->
Raft catch-up
  ->
SQLite catch-up
  ->
healthy replica
```

Leader fails:

One of the remaining members becomes leader.

Two servers fail:

`A ✓  B ✕  C ✕`

Consistent writes are rejected.

Erlite must never fabricate availability at the cost of split-brain.

## 14. Required invariants

1. A write is never acknowledged before Raft commit.
2. A successful write is not returned until the serving leader has applied the command to SQLite.
3. SQLite replicas apply committed commands in Raft-log order.
4. A committed command must never logically execute twice.
5. A newly elected leader must catch up its SQLite replica before serving consistent operations.
6. Schema changes use the same ordered replication mechanism as data changes.
7. Clients may not directly modify Erlite-managed SQLite files.
8. Cross-database transactions are unsupported.
9. Database creation, deletion, movement, and restoration are idempotent.
10. Loss of one member of a three-member group must not lose committed data.
11. Loss of quorum must stop consistent writes.
12. Joining and restarting nodes must not create duplicate logical identities.
13. Raft compaction must preserve a verified path for rebuilding every active SQLite replica.
14. A replica is not ready while its SQLite state is behind the index required by the operation being served.
15. Catalog generations fence stale create, delete, restore, move, repair, and rebalance work.
16. A database snapshot is not usable until its identity, generation, Raft position, and checksum are verified.

### Database lifecycle correctness

Operations that span the catalog and a per-database Raft group are coordinated workflows, not atomic cross-group transactions.

The catalog must record a durable lifecycle state, operation ID, and monotonically increasing placement generation. Expected states include:

- `creating`
- `ready`
- `moving`
- `restoring`
- `deleting`
- `tombstoned`
- `failed`

Every workflow step must be idempotent and fenced by the expected operation ID and generation. On restart, a reconciler resumes or safely rolls forward incomplete work. Stale workers must be unable to publish placement, activate replicas, or delete data for a newer generation.

Deletion first publishes a tombstone and fences new operations. Physical files are removed only after the active Raft group is safely retired and the configured retention/recovery policy permits removal. Reusing a deleted `DatabaseId` requires a new generation and must never reactivate stale replicas.

## 15. Repository structure

```text
erlite/
├── AGENTS.md
├── CLAUDE.md
├── ERLITE_PROJECT.md
├── README.md
├── rebar.config
├── apps/
│   ├── erlite_core/
│   ├── erlite_sqlite/
│   ├── erlite_raft/
│   ├── erlite_catalog/
│   ├── erlite_cluster/
│   ├── erlite_placement/
│   ├── erlite_api/
│   └── erlite_cli/
├── docs/
│   ├── architecture.md
│   ├── correctness.md
│   ├── replication.md
│   ├── clustering.md
│   ├── storage.md
│   ├── operations.md
│   ├── scaling.md
│   ├── migrations.md
│   └── adr/
└── test/
    ├── cluster/
    ├── failure/
    ├── integration/
    └── scale/
```

## 16. Core component responsibilities

### erlite_sqlite

Owns SQLite access:

- open
- close
- query
- execute
- transaction
- backup
- restore
- schema initialization
- applied-index management

SQLite implementation must be hidden behind a behaviour.

### erlite_raft

Owns per-database Raft groups:

- start group
- stop group
- submit command
- discover leader
- add member
- remove member
- read commit state
- recovery integration

Only one membership transition may be active for a database group at a time. Membership work must be fenced by catalog operation ID and placement generation and must use the supported `ra` membership-change protocol. A replacement is ready only after it has installed a verified base state, replayed through the required committed index, and passed readiness verification.

### erlite_replica

Owns local materialized SQLite replicas:

- track applied index
- apply committed commands
- recover after restart
- detect gaps
- catch up
- expose readiness
- expose health

### erlite_catalog

Owns:

- DatabaseId
- database state
- replica set
- replication factor
- schema version
- placement generation
- lifecycle state

### erlite_cluster

Owns:

- init cluster
- join cluster
- leave cluster
- node identity
- seed discovery
- health
- cluster status
- safe removal

### erlite_placement

Initially considers:

- replication factor
- node availability
- available disk
- database count

Later:

- database size
- reads/writes
- CPU
- memory
- IOPS
- network
- Raft group count
- leader count
- failure domains

### erlite_api

Data operations:

- query
- execute
- transaction

Control operations:

- create database
- delete database
- list databases
- database status
- backup
- restore
- move
- replication settings

### erlite_cli

Required:

```text
erlite init-cluster
erlite join <seed>
erlite leave
erlite cluster status
erlite node status <node>
erlite database create <id>
erlite database delete <id>
erlite database list
erlite database status <id>
```

## 17. Public Erlang API target

```erlang
erlite:create(<<"merchant-100">>, #{}).

erlite:execute(
    <<"merchant-100">>,
    <<"INSERT INTO products(sku,name) VALUES(?,?)">>,
    [<<"ABC1">>, <<"Product">>]
).

erlite:query(
    <<"merchant-100">>,
    <<"SELECT * FROM products WHERE sku = ?">>,
    [<<"ABC1">>]
).

erlite:transaction(<<"merchant-100">>, Statements).

erlite:backup(<<"merchant-100">>).

erlite:status(<<"merchant-100">>).
```

## 18. External API strategy

Erlang applications may use Erlite directly.

Non-Erlang applications use a network service.

Initial external interface:

- HTTP/JSON

Later:

- Protobuf/gRPC
- binary protocol
- PostgreSQL wire subset if justified
- language-specific drivers

Browser applications should normally communicate through an application backend.

## 19. Horizontal scaling model

Erlite primarily scales across databases, not inside one SQLite database.

Example:

```text
10,000 customers
    ->
10,000 databases
    ->
databases distributed across nodes
```

Each database has an independent SQLite writer and independent Raft group.

## 20. Scale-out by adding nodes

Initial:

`A B C`

Add:

`D`

Replica combinations may become:

```text
DB1 -> A B C
DB2 -> A B D
DB3 -> A C D
DB4 -> B C D
```

Applications continue using only `DatabaseId`.

## 21. Automatic replica repair

If RF=3 and one node fails:

```text
merchant-123
A ✓
D ✕
H ✓
```

After a configurable grace period Erlite should:

1. choose a healthy replacement node;
2. bootstrap the replacement replica;
3. catch it up;
4. verify applied state;
5. perform safe Raft membership transition;
6. retire the failed member from the active replica set.

Example result:

```text
merchant-123
A ✓
F ✓
H ✓
```

If the failed server later returns, its old copy must not automatically become a fourth live replica.

Repair and rebalancing for the same database must be mutually serialized. A stale or returning replica must prove that its database identity, placement generation, and Raft membership are current before activation; otherwise it remains quarantined pending cleanup or re-bootstrap.

## 22. Rebalancing

Adding nodes should eventually result in safe, incremental movement.

Never remove an old healthy replica before the replacement is ready.

Rebalancing must be throttled.

Movement must use a durable, resumable operation recorded in the catalog. The old healthy member is removed only after the new member is part of the intended Raft configuration, has applied through the verification index, and has passed integrity checks. Concurrent membership changes for one database are forbidden.

## 23. Migrations

Each database may have its own migration history.

Support:

- base application schema
- optional module migration packs
- tenant-specific migrations when required

Fleet migrations should eventually support:

- canary rollout
- batching
- pause/resume
- retries
- progress reporting
- compatibility checks

Avoid uncontrolled schema divergence.

## 24. Edge/offline mode

A future branch-local mode may remain writable while disconnected from the central system.

Do not implement this by bypassing Raft quorum.

Use:

- local authoritative database
- durable outbox/event log
- idempotent synchronization
- explicit data ownership
- eventual consistency between sites

## 25. Security

Production readiness requires:

- TLS on external APIs
- secure Erlang distribution over TLS
- node certificate verification
- private/firewalled distribution ports
- database-scoped credentials
- separate admin credentials
- filesystem permissions
- encrypted production disks
- encrypted backups
- audit logs
- parameterized SQL
- query/transaction timeouts
- storage quotas
- secret rotation

The application remains responsible for user-facing and business-level authorization. Erlite authenticates service and administrative identities and enforces which database IDs and control operations those identities may access. Database-scoped authorization in Erlite is a storage boundary; it does not replace application business rules.

## 25.1. Resource model and cold databases

The scale promise depends on bounded per-database overhead. Before claiming support for a database-count target, Erlite must define and measure budgets for:

- Erlang processes and memory per database and per Raft member
- open SQLite handles and file descriptors
- timers, ETS entries, and supervision children
- Raft log, snapshot, and metadata disk usage
- restart, activation, and catch-up concurrency

Cold databases may close SQLite handles and suspend nonessential local workers, but doing so must not violate Raft membership, committed-entry durability, repair detection, or readiness semantics. Activation must be rate-limited and must catch SQLite up to the required index before serving operations.

Scale validation begins with smaller staged tests during Phases 1 through 5; Phase 14 validates the final targets rather than discovering the basic resource model for the first time.

## 26. Development roadmap

### Phase 0 — Local SQLite abstraction

Build:

- OTP application
- supervision tree
- SQLite adapter
- create/open/delete DB
- query
- execute
- transaction
- tests

### Phase 1 — Replication correctness spike

Build:

- one 3-member Raft group
- deterministic transaction command
- committed-entry applier
- durable applied index
- restart catch-up
- recovery semantics
- deterministic-SQL enforcement
- coordinated Raft/SQLite snapshot and compaction recovery
- divergence detection

Exit criteria:

- crash between Raft commit and SQLite apply recovers without loss or double execution
- a replica behind the compacted log recovers from a verified snapshot and replays later entries
- duplicate delivery is harmless
- forbidden nondeterministic operations are rejected

### Phase 2 — Basic three-server Erlite cluster

**Status: complete**

Required:

- `erlite init-cluster`
- `erlite join`
- `erlite leave`
- `erlite cluster status`
- persistent node identity
- seed nodes
- cluster catalog
- RF=3
- quorum=2

### Phase 3 — Single-database HA

**Status: complete**

Validate:

- leader election
- consistent reads
- replicated writes
- safe recovery
- replica readiness

Exit criteria include a real three-node test covering follower loss, leader loss, restart, delayed SQLite apply, quorum loss, restoration of quorum, and linearizable reads across leadership change.

### Phase 4 — Multiple databases

**Status: complete**

Build:

- dynamic database supervisors
- registry
- dynamic Raft groups
- isolated SQLite files
- create/delete/list
- cold database strategy

Define and measure initial per-database resource budgets in this phase.

### Phase 5 — Distributed catalog and transparent routing

**Status: complete**

Phase 5 provides:

- replicated `DatabaseId` to replica-set records
- lifecycle states for `creating`, `ready`, `deleting`, and `tombstoned`
- consistent database lookup and incomplete-work discovery
- idempotent operation-ID and placement-generation fencing
- tombstone retention and next-generation reuse rules
- active-node placement validation and Ra server-ID collision prevention
- ready-only transparent `DatabaseId` resolution through consistent catalog reads
- generation-aware local route caching with configuration-epoch fencing
- Ra leader discovery validated against catalog placement and live membership
- catalog-first physical create and delete workflows accepting only `DatabaseId`
- deterministic RF=3 placement across active catalog nodes
- restart reconciliation of `creating` and `deleting` records
- idempotent completion of partially created SQLite replica sets
- interruption tests for create and delete reconciliation

Applications specify only `DatabaseId`.

Build:

- DB -> replica-set mapping
- leader lookup
- local routing cache
- lifecycle state
- catalog recovery
- durable lifecycle workflows and reconciliation
- operation-ID and generation fencing
- tombstone semantics

### Phase 6 — External service interface

**Status: complete**

The initial service is a supervised TLS-only HTTP/1.1 JSON boundary with
bounded requests and timeouts. It provides bearer-token service identities,
separate admin identities, database allow-list enforcement, consistent query,
replicated transaction, and database lifecycle/status endpoints. Query SQL is
restricted to single read-only statements and cannot access Erlite's internal
tables. Python and PHP examples are provided under `examples/`.

Build:

- network API
- TLS
- service authentication
- database authorization
- query API
- transaction API
- control API

Provide PHP and Python examples.

**Development checkpoint (2026-09-08):** Phase 7 is complete. Final verification
completed 80 EUnit tests and 14 Common Test cases, including real peer-node
expansion, movement, and crash reconciliation. Resume with Phase 8 automatic
replica repair.

### Phase 7 — Node expansion and database movement

**Status: complete**

Test 3 -> 4 nodes, then 4 -> 6 nodes.

Movement must be durable, resumable, serialized per database, and tested with crashes before and after every membership-transition step.

Phase 7 provides explicit, per-database movement to an active target node. The workflow durably bootstraps a verified SQLite snapshot, adds and catches up the replacement Ra member, removes the source only after replacement readiness, advances the placement generation, and reconciles interruption around membership changes. Real peer-node Common Tests cover expansion from 3 to 4 and 4 to 6 nodes, preserved data, final RF=3 membership, and controller/lifecycle crashes before and after membership transitions.

### Phase 8 — Automatic replica repair

Build:

- under-replication detection
- repair grace period
- replacement placement
- bootstrap/catch-up
- safe membership replacement
- stale/orphan cleanup

### Phase 9 — Automatic rebalancing

Build:

- imbalance detection
- migration planner
- migration queue
- concurrency limits
- safe movement

### Phase 10 — Backup and restore

Build:

- backup
- restore
- clone
- export

The backup format must include database identity, placement generation, SQLite/schema version, committed/applied Raft index and term, creation time, and integrity checksum. A backup is successful only when the SQLite image corresponds to its recorded applied index and verifies successfully.

Restore must have explicit modes:

- replace an existing database through a fenced `restoring` lifecycle operation; or
- clone into a new `DatabaseId` and new Raft history.

Restore must never silently attach an old SQLite image to an incompatible live Raft log. Backup-format and restore semantics must be designed during the replication phases even though the user-facing implementation is scheduled here.

### Phase 11 — Fleet migrations

Build:

- per-database migration history
- app/module migration sets
- canary rollout
- batching
- pause/resume
- retry/reporting

### Phase 12 — Placement improvements

Add:

- size awareness
- disk awareness
- load awareness
- leader balancing
- placement groups

### Phase 13 — Hardening

Add:

- network partitions
- repeated leader failures
- random process crashes
- delayed apply
- damaged replica recovery
- disk-full behavior
- rolling upgrades
- migration failures
- catalog failures
- backup corruption detection
- observability

### Phase 14 — Scale validation

Test progressively:

- 1,000 DBs
- 5,000 DBs
- 10,000+

Measure:

- RAM per DB
- RAM per Raft group
- provisioning latency
- query latency
- write latency
- failover latency
- catch-up time
- rebalance throughput
- disk usage
- file descriptors
- CPU
- network

### Phase 15 — Optional edge/offline mode

Only after the core cluster is stable.

## 27. Basic deployment acceptance test

1. Start three fresh Linux servers.
2. Initialize cluster on A.
3. Join B.
4. Join C.
5. Verify three healthy members.
6. Create DB.
7. Verify three replicas.
8. Write/read.
9. Kill follower.
10. Verify writes continue.
11. Restart follower.
12. Verify catch-up.
13. Kill leader.
14. Verify election.
15. Verify writes continue.
16. Restart old leader.
17. Verify convergence.
18. Stop two servers.
19. Verify consistent writes are rejected.
20. Restore one server.
21. Verify quorum and service resume.

## 28. Horizontal scaling acceptance test

Start with A, B, C.

Create 1,000 databases.

Add D, E, F.

Erlite must redistribute replicas without changing application DatabaseIds.

Safety is more important than perfect balance.

## 29. Explicit non-goals for v1

Do not implement:

- cross-database JOIN
- cross-database transaction
- global distributed SQL
- massive analytical processing
- multi-writer SQLite
- CRDTs
- Dynamo quorum semantics
- riak_core vnodes
- custom Raft
- PostgreSQL wire compatibility
- direct browser database access
- automatic multi-cluster federation

## 30. Future replication research

After transaction replication is correct, investigate:

- SQLite Session Extension
- SQLite changesets
- WAL replication
- page/frame replication
- snapshot optimization
- dedicated Rust/Rustler SQLite backend if needed

## 31. Flagship demonstration

Build a sample multi-tenant POS.

Provision 1,000 merchants.

Each merchant receives `merchant-N.sqlite`.

Demonstrate:

- create merchant
- execute sale
- query inventory
- fail follower
- continue sales
- fail leader
- recover
- add nodes
- repair replicas
- rebalance
- fleet migration
- backup one merchant
- restore one merchant

## 32. Product definition

Erlite is not SQLite that replaces PostgreSQL.

Erlite is:

> A distributed Erlang/OTP runtime for creating, replicating, placing, moving, repairing, migrating, and operating large numbers of small isolated SQLite databases.

Basic deployment promise:

> Install Erlite on three servers and get a replicated SQL database runtime with quorum-based failover.

Scaling promise:

> Add Erlite nodes to increase aggregate database, storage, read, and write capacity by distributing independent databases across the larger cluster.

Developer promise:

> Applications address a database by ID; Erlite determines where that database lives.
