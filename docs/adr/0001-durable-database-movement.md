# ADR 0001: Durable database movement

Status: accepted

## Context

Phase 7 must move an RF=3 SQLite database to a newly joined Erlite node without
making one SQLite database multi-writer, losing a committed transaction, or
making an unverified replica authoritative. RabbitMQ `ra` membership calls may
time out after taking effect, and any Erlite coordinator or database controller
may restart between physical steps.

## Decision

Each database has at most one catalog-persisted movement. It is fenced by the
database placement generation and a random operation ID and contains a source,
replacement, and phase.

The workflow is:

1. Commit an `adding` movement while leaving the advertised RF=3 placement
   unchanged.
2. Catch the source SQLite replica up to a quorum-confirmed Ra barrier.
3. Create a checksummed SQLite snapshot bound to the database, generation,
   applied index, term, schema version, and SQLite runtime identity.
4. Transfer the verified manifest and image over Erlang distribution, write and
   sync them on the target, install the image, and verify runtime compatibility.
5. Start the replacement `ra` server, add it to membership, catch its Ra machine
   up, apply through a fresh barrier, and verify its durable SQLite index.
6. Commit replacement readiness by changing the movement to `removing`.
7. Remove and delete the source Ra member, then close and delete its SQLite
   replica.

8. Atomically publish the new RF=3 placement, advance the placement generation,
   and clear the active movement.

If a crash occurs after committed source removal but before local file cleanup,
reconciliation may defer the idempotent cleanup without making the source live
or routable again.

Retries first inspect catalog state and actual Ra membership. Existing snapshot
artifacts, a started replacement, an already-added replacement, an already-
removed source, and a completed catalog transition are treated idempotently only
after their identities or membership are verified. A database controller being
reconstructed during movement accepts exactly the old three-member set, the
temporary four-member set, or the final replacement set.

Movement is serialized through the database lifecycle and local database
registry. Delete is refused while movement is active. Routing continues to use
the old placement during `adding`; the generation increment fences stale cached
placement after completion.

## Consequences

Movement temporarily uses four Ra members and one additional SQLite image. It
prioritizes recoverability over transfer cost. Automatic planning, throttling,
and repair remain later roadmap phases; Phase 7 exposes an explicit movement
operation and performs one movement per database at a time.
