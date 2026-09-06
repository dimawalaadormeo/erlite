# Erlite correctness model

`ERLITE_PROJECT.md` defines the complete target correctness model. This document records the guarantees implemented by the current code.

## Local materialization

Each Erlite-managed SQLite database contains one internal row in `__erlite_replica_metadata`. It records the storage format version and `last_applied_raft_index`.

`erlite_sqlite_schema:apply_committed/3` preserves these local invariants:

1. only positive, consecutive Raft indexes are newly applied;
2. an index at or below the durable applied index is treated as duplicate delivery and performs no SQL work;
3. an index above the next consecutive index is rejected as a gap;
4. only typed `execute` statements are accepted as replicated mutations; and
5. the mutations and applied-index update commit in one SQLite transaction or roll back together.

Schema initialization is idempotent and verifies the stored format version. Creation of a managed database initializes this metadata before reporting success.

## Local concurrency boundary

`erlite_sqlite_owner` is the serialized owner of an open managed database connection. SQL calls and applied-index operations sent through an owner execute in its `gen_server` mailbox order. `erlite_sqlite_databases` serializes local opens and returns the existing live owner when the same storage root and `DatabaseId` are opened again.

Managed create, close, and delete operations use the same registry. Delete removes a registered owner before synchronously stopping it, and removes the database files only after the connection has closed. Concurrent registry calls therefore cannot reopen that lifecycle instance between close and deletion.

The low-level adapter remains public within the umbrella for testing and component integration, but replicated application must go through the owner. Calling `erlite_sqlite_schema:apply_committed/3` concurrently on a raw connection is outside its contract.

Owner workers are temporary children. If an owner exits, its connection is closed and the local registry permits a later explicit reopen; the supervisor does not guess whether lifecycle policy wants the database restarted.

The Phase 1 spike now exercises Raft commit, missed-apply recovery, and snapshot-based replica bootstrap. It does not yet claim the production cluster lifecycle, cross-node operational behavior, placement fencing, or read modes assigned to later phases.

## Replicated command boundary

`erlite_raft_command` defines the initial `{transaction, TransactionId, SchemaVersion, Mutations}` command term. It rejects empty transaction IDs, negative schema versions, empty transactions, malformed mutations, and parameter values outside the normalized SQLite value types.

The initial replicated-SQL policy fails closed around a deliberately small parameterized DML grammar. Because accepted statements contain no SQL value expressions, functions, subqueries, ordering-dependent selection, collations, or additional statements, values that vary by host or execution time cannot enter through command SQL. Placeholder and parameter counts must match.

This statement policy is only one layer of determinism. Before applying replicated work, the applier also validates the local schema; production group admission must additionally coordinate the expected SQLite runtime identity and schema version.

## SQLite runtime compatibility

The local compatibility identity contains the SQLite version, SQLite source ID, and complete sorted `PRAGMA compile_options` result. Compatibility requires exact identity equality; matching version strings alone are insufficient. Mismatch errors report canonical SHA-256 fingerprints so operators can correlate builds without relying on unordered option output.

Runtime compatibility does not establish replica readiness by itself. The local schema must also pass `erlite_sqlite_schema_policy`, and the expected runtime identity must eventually be coordinated through the Raft group.

## SQLite schema determinism

The initial schema policy fails closed for schema objects that can execute hidden SQL, compute environment-dependent values, or depend on uncoordinated extensions and collations. It rejects triggers, views, virtual tables, defaults, generated columns, `CREATE TABLE AS`, `CHECK` constraints, collations, and explicit indexes. Erlite's exact internal metadata table is excluded from this inspection.

This conservative gate intentionally rejects some deterministic schemas. Supporting them later requires parser-backed inspection and replicated migration rules; silently admitting a potentially divergent schema is not acceptable.

## Raft machine durability boundary

`erlite_raft_machine` records each structurally and SQL-policy-valid transaction together with the index and term supplied by `ra`. It does not apply SQLite mutations and emits no effect on which durability depends. Its snapshotted state retains the ordered command ledger, allowing an independently retryable applier to recover materialization after missed notifications or Ra log compaction.

Raft indexes containing internal or membership entries can create gaps between application commands. The SQLite applier must therefore advance between the ordered application indexes supplied by this ledger; it must not assume every Raft index contains an Erlite transaction.

The machine's release-cursor effect permits Ra compaction only because the supplied machine snapshot contains the complete command ledger. Losing an effect cannot lose an acknowledged mutation: the durable Ra machine state remains authoritative, and SQLite catch-up is explicitly retried. Phase 1 does not prune that ledger.

## SQLite snapshot recovery and divergence

A Phase 1 snapshot is usable only when its manifest format, database identity, placement generation, minimum Raft position, safe image basename, SHA-256 checksum, and internal durable applied index all verify. A checksum or metadata mismatch marks the artifact incompatible; it is never activated. This provides divergence/corruption detection at the defined snapshot verification point.

Snapshot creation is serialized by the database owner and uses SQLite's `VACUUM INTO` to obtain a consistent standalone image. Installation first copies the verified image to a uniquely named file in the destination directory, syncs it, closes any registered owner, and atomically renames it over the inactive database path. WAL sidecars from the prior image are removed only after activation. Replay then starts strictly after the snapshot's durable applied index.

The manifest itself is synced before publication. A future production snapshot catalog must additionally sync containing directories and coordinate retention across nodes before allowing the command ledger to be pruned.

## Persistent node identity

Phase 2 node identity creation uses exclusive file creation and syncs the identity before returning success. Subsequent starts must load the same 128-bit ID and configured node name. A truncated or malformed identity, unsupported format version, or conflicting configured node name stops bootstrap; Erlite never silently assigns a replacement identity that could duplicate catalog membership.

## Cluster catalog bootstrap

The catalog group bootstraps with one member and reaches its required topology through verified joins. Its replicated state records distinct persistent node IDs and names, target RF=3, and quorum=2. Invalid or duplicate identities fail before a new Ra server is started. A bootstrap catalog is not production-ready until three nodes are active. Authoritative status is obtained with `ra:consistent_query/3`; callers must opt into potentially stale local status explicitly.

Catalog node lifecycle changes are explicit replicated transitions: `joining` precedes activation and `leaving` precedes removal. Each transition is idempotent, identity collisions fail closed, and an interrupted external Ra membership workflow remains visible for reconciliation instead of falsely reporting the node active or absent.

A joining node is not marked active until its Ra membership is committed and its local catalog machine can answer from caught-up state. A leave is refused when only three active catalog nodes remain, preserving RF=3 until a replacement is joined. For an allowed removal, the catalog records `leaving` before Ra's consensus-backed membership removal and deletes the departed Ra server before catalog finalization. Failures leave a visible transitional state for retry.

Before `init-cluster` starts Ra, it exclusively persists an `initializing` record containing the generated cluster ID and configured name. A retry always reuses this cluster ID. Join persists the cluster identity learned through a consistent seed query before changing membership. Local metadata becomes `active` only after the node is active in the catalog. Atomic replacement and file sync prevent a partially written state transition from being accepted after restart.
