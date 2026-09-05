# Erlite architecture

`ERLITE_PROJECT.md` is the primary project specification. This document records the architecture implemented so far.

## OTP applications

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

## Local database files

`erlite_sqlite_database` owns Phase 0 database-file creation, opening, and deletion. It accepts only a non-empty binary `DatabaseId` of at most 1,024 bytes and an absolute storage root.

Database IDs are never escaped into filenames. The filename is `db-<sha256>.sqlite`, where the digest is the lowercase SHA-256 of the complete ID. The catalog will retain the ID-to-database relationship in later phases; filenames are deliberately opaque.

Creation uses exclusive file creation to prevent accidental replacement and restricts the resulting file to owner access. Opening and deletion reject symbolic links and non-regular files. Deletion is idempotent and also removes SQLite WAL and shared-memory artifacts. Callers must close a database before deleting it; lifecycle serialization will enforce this when the local database supervisor is implemented.
