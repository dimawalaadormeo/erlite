# Erlite correctness model

`ERLITE_PROJECT.md` defines the complete target correctness model. This document records the guarantees implemented by the current code.

## Local materialization

Each Erlite-managed SQLite database contains one internal row in `__erlite_replica_metadata`. It records the storage format version and `last_applied_raft_index`.

`erlite_sqlite_schema:apply_committed/6` preserves these local invariants:

1. only positive, increasing Raft application indexes are newly applied;
2. an index at or below the durable applied index is treated as duplicate delivery and performs no SQL work;
3. the caller's expected durable index must match, while gaps caused by non-application Raft entries are permitted;
4. only typed `execute` statements are accepted as replicated mutations; and
5. the transaction ID, command hash, mutations, and applied-index update commit in one SQLite transaction or roll back together;
6. the same transaction ID and command hash at a later Raft index skips the mutations but durably advances the applied index; and
7. reuse of a transaction ID with different content is a deterministic no-op conflict that does not block later committed entries.

Schema initialization is idempotent and verifies the stored format version. Creation of a managed database initializes this metadata before reporting success.

## Local concurrency boundary

`erlite_sqlite_owner` is the serialized owner of an open managed database connection. SQL calls and applied-index operations sent through an owner execute in its `gen_server` mailbox order. `erlite_sqlite_databases` serializes local opens and returns the existing live owner when the same storage root and `DatabaseId` are opened again.

Managed create, close, and delete operations use the same registry. Delete removes a registered owner before synchronously stopping it, and removes the database files only after the connection has closed. Concurrent registry calls therefore cannot reopen that lifecycle instance between close and deletion.

The low-level adapter remains public within the umbrella for testing and component integration, but replicated application must go through the owner. Calling `erlite_sqlite_schema:apply_committed/6` concurrently on a raw connection is outside its contract. The former consecutive-index helper has been removed because application-command indexes may legitimately contain Raft gaps.

Owner workers are temporary children. If an owner exits, its connection is closed and the local registry permits a later explicit reopen; the supervisor does not guess whether lifecycle policy wants the database restarted.

The Phase 1 spike exercises Raft commit, missed-apply recovery, and snapshot-based replica bootstrap. Placement fencing and the multiple-database lifecycle remain assigned to later phases.

## Single-database high availability

Phase 3 routes an accepted write to Ra and acknowledges it only after the Ra-reported leader's SQLite owner has durably applied through the committed command index. Loss of a follower does not block a quorum write. Loss of the leader causes Ra to elect a replacement; the replacement must materialize all committed application commands before the write can be acknowledged.

A consistent read begins with `ra:consistent_query/3`. The returned barrier contains the leader machine's applied Raft index and term plus the latest application-command index represented by that state. The read is issued only after the same leader's SQLite owner has caught up through that command index. Consequently, the SQLite result contains every write committed before the barrier, including across a leadership change.

Replica readiness is an active check rather than a node-up flag. It obtains a consistent barrier, verifies the selected member against the replicated SQLite runtime identity, waits until its Ra machine has applied that barrier, applies all missing retained commands in order, and reports ready only when the durable SQLite index reaches the barrier's application-command index.

Without quorum, neither writes nor consistent reads return success. A command that times out has an ambiguous outcome: it may commit after quorum is restored. Retrying identical content with the same transaction identity is safe because every SQLite replica durably compares the command hash and executes its mutations once. Reusing that identity for different content returns `transaction_id_conflict` and executes neither version a second time.

## Replicated command boundary

`erlite_raft_command` defines the initial `{transaction, TransactionId, SchemaVersion, Mutations}` command term. It rejects empty transaction IDs, negative schema versions, empty transactions, malformed mutations, and parameter values outside the normalized SQLite value types.

The initial replicated-SQL policy fails closed around a deliberately small parameterized DML grammar. Because accepted statements contain no SQL value expressions, functions, subqueries, ordering-dependent selection, collations, or additional statements, values that vary by host or execution time cannot enter through command SQL. Placeholder and parameter counts must match.

This statement policy is only one layer of determinism. Before applying replicated work, the applier verifies the runtime identity stored in the Raft group and validates the local schema. Schema-version admission remains part of the migration work in a later phase.

## SQLite runtime compatibility

The local compatibility identity contains the SQLite version, SQLite source ID, and complete sorted `PRAGMA compile_options` result. Compatibility requires exact identity equality; matching version strings alone are insufficient. Mismatch errors report canonical SHA-256 fingerprints so operators can correlate builds without relying on unordered option output.

Runtime compatibility does not establish replica readiness by itself. The local schema must also pass `erlite_sqlite_schema_policy`, Raft must be caught up through the read barrier, and SQLite must be applied through its application-command index. The expected runtime identity is immutable replicated group state and is also bound into recovery snapshots.

## SQLite schema determinism

The initial schema policy fails closed for schema objects that can execute hidden SQL, compute environment-dependent values, or depend on uncoordinated extensions and collations. It rejects triggers, views, virtual tables, defaults, generated columns, `CREATE TABLE AS`, `CHECK` constraints, collations, and explicit indexes. Erlite-owned tables with the reserved `__erlite_` prefix are excluded from this inspection.

This conservative gate intentionally rejects some deterministic schemas. Supporting them later requires parser-backed inspection and replicated migration rules; silently admitting a potentially divergent schema is not acceptable.

## Raft machine durability boundary

`erlite_raft_machine` records each structurally and SQL-policy-valid transaction together with the index and term supplied by `ra`. It does not apply SQLite mutations and emits no effect on which durability depends. Its snapshotted state retains the ordered commands newer than the last verified checkpoint, allowing an independently retryable applier to recover materialization after missed notifications or Ra log compaction.

Raft indexes containing internal or membership entries can create gaps between application commands. The SQLite applier must therefore advance between the ordered application indexes supplied by this ledger; it must not assume every Raft index contains an Erlite transaction.

The machine accepts a pruning checkpoint only after the coordinator has caught up every listed replica and created and verified a compatible SQLite snapshot at the same application index. The committed checkpoint records each member's manifest and removes only covered commands. A replica below that floor receives `snapshot_required`; it is never allowed to replay only the suffix. Checkpoint frequency and retained snapshot count will receive explicit per-database budgets in Phase 4.

## SQLite snapshot recovery and divergence

A snapshot is usable only when its manifest format, database identity, placement generation, minimum Raft position, SQLite runtime identity, safe image basename, SHA-256 checksum, and internal durable applied index all verify. A checksum, runtime, or metadata mismatch marks the artifact incompatible; it is never activated. The snapshotted transaction registry preserves logical-write deduplication after installation.

Snapshot creation is serialized by the database owner and uses SQLite's `VACUUM INTO` to obtain a consistent standalone image. Installation first copies the verified image to a uniquely named file in the destination directory, syncs it, closes any registered owner, and atomically renames it over the inactive database path. WAL sidecars from the prior image are removed only after activation. Replay then starts strictly after the snapshot's durable applied index.

The image and manifest are synced and the containing directory is synced before publication. Ledger pruning is a replicated checkpoint performed only after every active replica has a verified manifest. Snapshot retention and replacement policy remain lifecycle work for Phase 4.

## Persistent node identity

Phase 2 node identity creation uses exclusive file creation and syncs the identity before returning success. Subsequent starts must load the same 128-bit ID and configured node name. A truncated or malformed identity, unsupported format version, or conflicting configured node name stops bootstrap; Erlite never silently assigns a replacement identity that could duplicate catalog membership.

## Cluster catalog bootstrap

The catalog group bootstraps with one member and reaches its required topology through verified joins. Its replicated state records distinct persistent node IDs and names, target RF=3, and quorum=2. Invalid or duplicate identities fail before a new Ra server is started. A bootstrap catalog is not production-ready until three nodes are active. Authoritative status is obtained with `ra:consistent_query/3`; callers must opt into potentially stale local status explicitly.

Catalog node lifecycle changes are explicit replicated transitions: `joining` precedes activation and `leaving` precedes removal. Each transition is idempotent, identity collisions fail closed, and an interrupted external Ra membership workflow remains visible for reconciliation instead of falsely reporting the node active or absent.

A joining node is not marked active until its Ra membership is committed and its local catalog machine can answer from caught-up state. A leave is refused when only three active catalog nodes remain, preserving RF=3 until a replacement is joined. For an allowed removal, the catalog records `leaving` before Ra's consensus-backed membership removal and deletes the departed Ra server before catalog finalization. Failures leave a visible transitional state for retry.

Before `init-cluster` starts Ra, it exclusively persists an `initializing` record containing the generated cluster ID and configured name. A retry always reuses this cluster ID. Join persists the cluster identity learned through a consistent seed query before changing membership. Local metadata becomes `active` only after the node is active in the catalog. Atomic replacement and file sync prevent a partially written state transition from being accepted after restart.

## Multiple-database lifecycle

Phase 4 assigns every database its own dynamic controller, three-member Ra group, replica-owner map, and hashed SQLite files. The local lifecycle coordinator serializes create and delete and rejects database-ID or Ra-server-ID reuse, preventing one database from addressing another database's consensus or storage resources.

Database routes are stored in a protected ETS index and reads do not enter the lifecycle coordinator mailbox. A slow create or delete therefore cannot block routing to an already-running database. If the coordinator exits, its supervisor restarts it and it reconstructs routes and monitors from the surviving database children before serving lifecycle calls. During the short interval in which the ETS index does not exist, routing fails explicitly with `database_registry_unavailable`; it never converts that condition into a successful no-op delete. Remote replica lifecycle operations have finite timeouts.

Create is all-or-nothing within the Phase 4 local workflow. Rollback records only replicas created by that invocation; a pre-existing database file causes failure and is never treated as rollback-owned data. Delete first removes the database's Ra servers, then closes SQLite owners, then deletes only that database's hashed replica files. Repeated delete through the registry is harmless.

Cooling removes open SQLite handles without changing Ra membership or deleting durable state. Reactivation verifies runtime compatibility before returning the database to active mode. Consistent reads and writes still pass through the Phase 3 barrier and catch-up rules after activation.

The initial active RF=3 resource budget enforced by Common Test is 256 KiB for the controller, 1.5 MiB across three SQLite owners, 3 MiB across three primary Ra server processes, and 384 KiB across three empty SQLite files. On OTP 29.0.3 in the test profile, the measured values were 42,424 bytes, 49,496 bytes, 147,716 bytes, and 49,152 bytes respectively. These are regression budgets for the measured primary processes, not final whole-VM capacity claims; Phase 14 remains responsible for large-scale validation including auxiliary Ra processes, ETS, timers, descriptors, and loaded-code sharing.

## Catalog-fenced database lifecycle

Phase 5 database records are durable Ra machine state. Creation begins at generation one for a previously unknown ID. A tombstoned ID may be recreated only at exactly the following generation. The catalog accepts an identical retry of a transition, but a different operation ID at the same generation or any mismatched generation fails closed. Readiness can only follow `creating`; tombstoning can only follow `deleting` with the same operation ID and generation.

Records in `creating` or `deleting` are returned by the catalog recovery query so the lifecycle service can resume them after process or node restart. Publishing `ready` and `tombstoned` is deliberately separate from physical work: replica creation or retirement must complete before the corresponding terminal state is committed. Physical creation is an idempotent ensure operation: it reopens compatible existing replicas, creates missing replicas, and rolls back only files created by the failing attempt. A tombstone remains authoritative and preserves its generation; deleting local files alone never permits reuse of the ID.

Create placement is derived from active catalog membership and bound to the catalog record before physical work begins. Ra server IDs include the database digest, placement generation, and replica ordinal, so recreating a tombstoned database cannot accidentally address a stale generation. Reconciliation always uses the recorded placement and operation ID; it never chooses a replacement placement for an in-progress operation.

Deletion reconciliation never interprets an empty local controller registry as proof that durable resources are absent. When no controller exists, it directly tears down the exact catalog-recorded Ra members and SQLite paths without trying to form a second Ra cluster, and only then publishes the tombstone. Non-benign Ra removal failures leave the record in `deleting`. This makes deletion recoverable after a complete Erlite runtime restart, where dynamic database children are intentionally absent.

Database routing is authorized by a consistent read of the catalog on every resolution. Only a `ready` record may produce a route; `creating`, `deleting`, and `tombstoned` records fail closed and evict any local cached route. A missing or unavailable catalog is never replaced by cached authorization. The local routing cache therefore cannot extend the lifetime of a route beyond its authoritative catalog state.

Leader discovery begins from the replica set returned by that consistent lookup. A reported leader is accepted only if it appears in both Ra's current membership response and the catalog replica set. Cached updates carry the catalog-configuration epoch and record generation; delayed updates from a previous configuration are discarded, and an older generation cannot replace a newer cached generation.

## Durable database movement

Phase 7 movement starts by durably recording a single operation-ID-fenced source and replacement on an otherwise ready database. The authoritative RF=3 replica set is not changed during the `adding` phase. A quorum barrier first fixes the source SQLite applied index. A snapshot binds that index, Ra term, database ID, placement generation, schema version, checksum, and SQLite runtime identity; its image and manifest are synced on the target and verified before installation. The replacement Ra server is then added and must catch up both Ra state and SQLite through a fresh quorum barrier before the catalog can transition to `removing`.

Source removal is allowed only from `removing`. An ambiguous add or remove result is reconciled against Ra's committed membership before retry. The old SQLite replica is deleted only after Ra reports the source absent. Placement substitution and generation advancement occur only afterward. Every catalog transition is idempotent, incomplete movement is returned for reconciliation, and a target must be an active catalog node whose Ra server ID is unused. Delete is fenced while a move is incomplete. Controller reconstruction accepts only the old RF=3 set, the temporary four-member set, or the final RF=3 replacement set and derives stable storage roots for both original and replacement replicas. Consequently a crash cannot make an unverified replacement authoritative, silently overlap two movements, race physical deletion, or resurrect a removed source as a blank replica.

## Automatic replica repair

Phase 8 marks a ready RF=3 database under-replicated only when exactly one
catalog member is unhealthy and the other two named Ra servers are reachable.
The catalog durably stores the failed server, detection time, and operation ID.
A recovered server clears a waiting repair; a repair cannot start before the
configured grace period, with fewer than two healthy members, without an
active replacement node, or while another movement is in progress.

Repair is a catalog-fenced specialization of durable movement. Snapshot and
bootstrap use a surviving SQLite replica. The replacement is added, caught up
through a quorum barrier, and verified before the failed member is removed
from committed Ra membership. Failure to find or prepare a target leaves the
original RF=3 membership unchanged and is retried. Completion advances the
placement generation and records the removed server as stale. The stale server
is never returned by catalog routing; if its node comes back, its old Ra server
and SQLite image are deleted before the stale marker is cleared. Cleanup also
continues after database deletion. These transitions are idempotent and the
repair and movement fences prevent overlapping membership changes.

## Automatic rebalancing

Rebalancing does not introduce a new membership-change path. The planner
selects only ready databases with no repair or movement record and only healthy
active source and target nodes. Every selected migration enters the durable,
catalog-fenced movement workflow, preserving snapshot verification, replacement
catch-up, membership ordering, source retirement, and generation advancement.

Planning is catalog-leader-owned and bounded per scan. Projected counts change
after each selection, and one database cannot appear twice in a queue. On a
worker crash or leader change, the next scan reconstructs its plan from a
consistent catalog read. A submitted migration remains durable and resumable;
catalog operation-ID and generation fences prevent another planner or repair
worker from overlapping it.

## External service boundary

Phase 6 never exposes a plaintext listener. Enabling the HTTP service requires TLS certificate material and at least one configured bearer credential. Tokens are compared in constant time and removed from the authenticated identity before dispatch. Admin authorization is required for create, delete, and fleet listing; service identities can access only their explicit database allow-list.

Every data request performs a consistent ready-state catalog lookup before attaching to the recorded Ra group. Reads still use the quorum barrier and SQLite catch-up path. The external query policy accepts one `SELECT` statement, rejects comments, multiple statements, mutation and administrative keywords, and Erlite internal table names. After catch-up, the serialized SQLite owner enables `PRAGMA query_only` for the query and restores it before servicing another operation, making SQLite itself reject mutation attempts. If restoring writable mode fails, the owner terminates instead of remaining available in a state that cannot apply committed entries; the failure propagates through the temporary database controller so a later route reattaches fresh processes and connections. Writes are typed transactions submitted through the deterministic Ra command policy. A transaction timeout remains an ambiguous outcome and clients must retry identical content with the same transaction ID.
