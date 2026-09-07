# Erlite architecture

`ERLITE_PROJECT.md` is the primary project specification. This document records the architecture implemented so far.

## OTP applications

### `erlite_raft`

`erlite_raft` owns the replicated command and consensus boundary. It defines the versioned transaction-command term described in `ERLITE_PROJECT.md` and validates transaction IDs, schema versions, mutation structure, SQLite parameter value types, and the initial replicated-SQL policy before submission. `erlite_raft_cluster` starts a three-member RabbitMQ `ra` group and submits only validated commands.

The initial SQL policy is intentionally narrow. It accepts parameterized `INSERT ... VALUES`, simple `UPDATE ... SET ...` with optional equality predicates, and `DELETE ... WHERE ...`, using bare ASCII identifiers. Values must be supplied as parameters. DDL, SQL expressions and functions, subqueries, comments, multiple statements, collations, `RETURNING`, and other SQL forms are rejected. Broader SQL support requires parser-backed validation plus schema-level checks for triggers, generated columns, defaults, and collations.

`erlite_raft_machine` is a pure `ra_machine`. It retains validated transaction commands with their authoritative Raft index and term and performs no SQLite side effects. It releases Ra's log cursor with machine state containing the retained recovery ledger. A coordinated checkpoint first catches up every replica and creates and verifies a runtime-compatible SQLite snapshot for each member; only the committed checkpoint then removes covered ledger entries. Requests below the retained floor receive `snapshot_required` instead of incomplete replay data.

`erlite_raft_applier` queries committed machine state and atomically applies missing transactions through the serialized SQLite owner. A successful write reply requires both Raft commit and leader SQLite application through the returned commit index. Missed application is recovered from the SQLite durable index after reopen.

Phase 3 adds `erlite_raft_database` as the single-database HA boundary. Its replica map associates each Ra server ID with the SQLite owner on that member. Writes may enter through any available Ra member, but SQLite catch-up and acknowledgement are routed to the leader returned by Ra. Consistent reads first execute a Ra quorum-confirmed barrier, catch the leader's SQLite owner up through that barrier, and only then query SQLite.

The barrier binds the Ra machine's applied index and term to its latest retained application-command index and the group's authoritative SQLite runtime identity. Follower readiness first verifies that runtime identity, then waits until the follower Ra machine has applied the exact barrier and its SQLite owner has materialized every application command through the barrier's command index. A member that cannot satisfy all conditions is not ready.

`erlite_raft_snapshot` creates a transactionally consistent SQLite image with `VACUUM INTO`. Its manifest binds the database identity, placement generation, Raft index and term, schema version, SQLite runtime identity, image name, format version, and SHA-256 checksum. The image, manifest, and containing directory are synced before checkpoint publication. Installation validates all bindings, runtime compatibility, and the image's internal applied index, copies and syncs a temporary file, closes a live owner, then atomically renames the image into place. Later Raft entries are replayed by the normal applier.

### `erlite_core`

`erlite_core` owns the top-level Erlite supervision tree. Phase 4 adds `erlite_database_sup`, a dynamic supervisor with one temporary controller per database, and `erlite_databases`, the serialized local lifecycle coordinator. The coordinator owns a protected, read-concurrent ETS route index. Create and delete remain serialized, while list, status, consistent query, replicated write, and cooling resolve their database controller directly through ETS and therefore do not queue behind an unrelated lifecycle operation. The coordinator refuses reuse of a Ra server ID by another database.

If the lifecycle coordinator restarts, it rebuilds its monitors, placement checks, and ETS routes by enumerating the surviving dynamic-supervisor children and reading their immutable database identity and server IDs. A missing ETS table is reported as registry unavailable rather than as database absence. Cross-node controller lifecycle calls use finite RPC timeouts so an unavailable placement member cannot block the coordinator forever.

Each `erlite_database` owns one explicit three-member Ra group plus one isolated SQLite file per replica root. Phase 4 callers provide the server IDs and storage root; choosing nodes and persisting database placement remain Phase 5 catalog responsibilities. Create rollback tracks exactly which files were made by the current attempt, so encountering a pre-existing file never deletes it.

Phase 5 adds the supervised `erlite_database_router`. It is configured with the catalog Ra server reference and resolves an application-supplied `DatabaseId` through a consistent catalog query. Only `ready` records are routable. Leader discovery asks the database's Ra members for their current leader and accepts the result only when it belongs to both the live membership response and the catalog replica set.

The router maintains a protected, read-concurrent ETS cache containing the observed generation, catalog record, and discovered leader. This cache is a local hint for reuse and inspection; route authorization always performs a fresh consistent catalog lookup. Reconfiguration clears the cache and changes an epoch token, so delayed updates produced under an older catalog configuration cannot repopulate it.

The supervised `erlite_database_lifecycle` service is the Phase 5 control path. Create and delete accept only a `DatabaseId`. Create chooses three active catalog nodes, derives generation-specific Ra server IDs, commits `creating`, idempotently ensures the physical SQLite replicas and Ra group, and only then commits `ready`. Delete commits `deleting`, retires the local controller, Ra servers, and SQLite replicas, and only then commits `tombstoned`. On configuration or restart it consistently queries all incomplete catalog records and resumes them. The physical ensure operation can reopen a complete durable replica set or finish a partially created set without deleting pre-existing replicas during rollback.

A cold database closes its SQLite owners but keeps its Ra membership and durable files. Its next read or write reopens every owner, verifies the group's runtime identity, catches the serving replica up through a quorum barrier, and only then serves the operation. Database status reports lifecycle mode, open-owner count, replica file bytes, and sampled controller, SQLite-owner, and Ra-server process memory.

Phase 2 node bootstrap begins with `erlite_node_identity`. The identity is stored under `<storage_path>/node/identity` with owner-only permissions and contains a format version, a stable random 128-bit node ID, and the configured distributed Erlang node name. Creation is exclusive, concurrent creators reload the winner, and malformed, unsupported, or name-conflicting identities fail closed instead of being replaced.

`erlite_cluster_config` resolves application configuration with `ERLITE_*` environment overrides for container deployment. Phase 2 fixes replication factor at three, canonicalizes duplicate seed nodes, requires absolute storage paths, and validates distributed node names before bootstrap can touch persistent state.

### `erlite_catalog`

The Phase 2 cluster catalog is a dedicated RabbitMQ `ra` group that bootstraps with one member and must expand to three before it is production-ready. Its replicated state binds the cluster ID and name to unique persistent node IDs, node names, and Ra server IDs, and records target RF=3 with quorum=2. Catalog status uses a Ra consistent query; local status is explicitly separate and may be stale.

Phase 5 extends that same authoritative group with per-database records. A record contains `DatabaseId`, lifecycle state, a 128-bit operation ID, monotonically increasing placement generation, exactly three Ra server IDs, replication factor, and schema version. Catalog commands prepare creation, publish readiness, prepare deletion, and publish a tombstone; consistent lookup and incomplete-work discovery expose the state required by routing and reconciliation.

Catalog join and leave are staged workflows. Join first records `joining`, starts the new Ra server, commits Ra membership, verifies that member can read caught-up local machine state, and only then records `active`. Leave records `leaving`, uses Ra's consensus-backed leave-and-delete operation, and finalizes removal through surviving members. Phase 2 refuses a leave that would reduce active catalog nodes below three; later automatic replacement must add and verify a replacement before removal.

`erlite_cluster` is the operational facade behind `erlite_cli`. `init-cluster` creates a one-member bootstrap catalog that is expanded by `join` to the required three members; a cluster is not production-ready until status reports three active nodes. Local cluster metadata is persisted at `<storage_path>/node/cluster` before Ra bootstrap and transitions from `initializing` to `active` only after the local catalog is usable. `cluster status` is a consistent catalog query, not a local-file projection.

### `erlite_sqlite`

`erlite_sqlite` is the only boundary through which Erlite components access SQLite. Callers receive an opaque connection and use normalized Erlite request and result types. Backend-specific connection handles and result formats do not escape this application.

The backend is selected by the `adapter` option to `erlite_sqlite:open/2`, or by the `erlite_sqlite` application environment. The default backend is `erlite_sqlite_esqlite`, which adapts the pinned `esqlite` dependency. Tests can inject another adapter explicitly without exposing that choice to callers using an opened connection.

A backend implements `erlite_sqlite_adapter` and must provide:

- connection open and close
- parameterized execution and querying
- atomic execution of a typed statement list

Transactions use `{execute, Sql, Params}` and `{query, Sql, Params}` statements. A backend must commit every statement or roll back the complete list on error. The future replicated-command validator will decide which SQL is safe to submit; the adapter boundary does not make arbitrary SQL deterministic.

The adapter choice is intentionally separate from lifecycle, placement, and Raft logic. Replacing the SQLite NIF must not alter those components.

The `esqlite` backend normalizes SQLite `NULL` to the Erlite atom `null`, preserves statement-result order, and implements transactions with `BEGIN IMMEDIATE`, `COMMIT`, and rollback on statement or commit failure. Open options are rejected unless explicitly implemented so configuration is never silently ignored.

`erlite_sqlite_compatibility` derives a canonical runtime identity from SQLite's version, source ID, and sorted compile options. Replicas compare the complete identity and use its SHA-256 fingerprint in mismatch errors. The supervised owner exposes this check so compatibility inspection is serialized with other access to the connection.

`erlite_sqlite_schema_policy` provides the initial replication-readiness schema gate. It accepts ordinary tables with primary keys, uniqueness, and foreign keys, but conservatively rejects triggers, views, virtual tables, defaults, generated columns or `CREATE TABLE AS`, `CHECK`, collations, and explicit indexes. These restrictions can be relaxed only with parser-backed validation that preserves deterministic behavior.

## Local database files

`erlite_sqlite_database` owns Phase 0 database-file creation, opening, and deletion. It accepts only a non-empty binary `DatabaseId` of at most 1,024 bytes and an absolute storage root.

Database IDs are never escaped into filenames. The filename is `db-<sha256>.sqlite`, where the digest is the lowercase SHA-256 of the complete ID. The catalog will retain the ID-to-database relationship in later phases; filenames are deliberately opaque.

Creation uses exclusive file creation to prevent accidental replacement and restricts the resulting file to owner access. Opening and deletion reject symbolic links and non-regular files. Deletion is idempotent and also removes SQLite WAL and shared-memory artifacts. Managed lifecycle calls go through `erlite_sqlite_databases`; deleting an open database first synchronously closes its owner and SQLite connection.

Every newly created managed database is initialized with Erlite's internal replica metadata and transaction-ID registry. `erlite_sqlite_schema` owns its format version, durable applied Raft index, and durable command hashes. First application records the transaction ID and mutations atomically; a retry with the same ID and hash skips mutations while advancing the new Raft index, and reuse with different content becomes a deterministic no-op conflict. Replicated application uses the supervised owner described below to enforce single-file serialization.

### Supervised connection ownership

`erlite_sqlite_sup` starts a dynamic owner supervisor and the `erlite_sqlite_databases` local registry. The registry serializes create, open, close, and delete calls for each node. Opening a managed database through it yields one `erlite_sqlite_owner` per `{StorageRoot, DatabaseId}`. The owner serializes queries, executions, transactions, and committed-entry application and closes its SQLite connection during termination.

Owner workers use temporary restart semantics. Unexpected exit closes the current lifecycle instance; a caller must reopen it explicitly. This avoids restarting a database after a future catalog operation has deleted, moved, or fenced that generation.
