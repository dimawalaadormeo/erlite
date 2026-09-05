# Erlite architecture

`ERLITE_PROJECT.md` is the primary project specification. This document records the architecture implemented so far.

## OTP applications

### `erlite_raft`

`erlite_raft` owns the replicated command and consensus boundary. It defines the versioned transaction-command term described in `ERLITE_PROJECT.md` and validates transaction IDs, schema versions, mutation structure, SQLite parameter value types, and the initial replicated-SQL policy before submission. `erlite_raft_cluster` starts a three-member RabbitMQ `ra` group and submits only validated commands.

The initial SQL policy is intentionally narrow. It accepts parameterized `INSERT ... VALUES`, simple `UPDATE ... SET ...` with optional equality predicates, and `DELETE ... WHERE ...`, using bare ASCII identifiers. Values must be supplied as parameters. DDL, SQL expressions and functions, subqueries, comments, multiple statements, collations, `RETURNING`, and other SQL forms are rejected. Broader SQL support requires parser-backed validation plus schema-level checks for triggers, generated columns, defaults, and collations.

`erlite_raft_machine` is a pure `ra_machine`. It retains validated transaction commands with their authoritative Raft index and term and performs no SQLite side effects. It releases Ra's log cursor with the complete new machine state, so a Ra snapshot preserves the ledger needed by the independently retryable SQLite applier after log compaction. The Phase 1 ledger is deliberately unbounded; pruning it is unsafe until every active replica has a verified SQLite snapshot recovery path.

`erlite_raft_applier` queries committed machine state and atomically applies missing transactions through the serialized SQLite owner. A successful write reply requires both Raft commit and leader SQLite application through the returned commit index. Missed application is recovered from the SQLite durable index after reopen.

`erlite_raft_snapshot` creates a transactionally consistent SQLite image with `VACUUM INTO`. Its manifest binds the database identity, placement generation, Raft index and term, schema version, image name, format version, and SHA-256 checksum. Installation validates all bindings and the image's internal applied index, copies and syncs a temporary file, closes a live owner, then atomically renames the image into place. Later Raft entries are replayed by the normal applier.

### `erlite_core`

`erlite_core` owns the top-level Erlite supervision tree. It currently starts with no children so later components can be added deliberately with explicit restart and failure semantics.

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

Every newly created managed database is initialized with Erlite's internal replica metadata. `erlite_sqlite_schema` owns its format version and durable applied Raft index. Mutation statements and the corresponding applied-index advance use one adapter transaction. Replicated application uses the supervised owner described below to enforce single-file serialization.

### Supervised connection ownership

`erlite_sqlite_sup` starts a dynamic owner supervisor and the `erlite_sqlite_databases` local registry. The registry serializes create, open, close, and delete calls for each node. Opening a managed database through it yields one `erlite_sqlite_owner` per `{StorageRoot, DatabaseId}`. The owner serializes queries, executions, transactions, and committed-entry application and closes its SQLite connection during termination.

Owner workers use temporary restart semantics. Unexpected exit closes the current lifecycle instance; a caller must reopen it explicitly. This avoids restarting a database after a future catalog operation has deleted, moved, or fenced that generation.
