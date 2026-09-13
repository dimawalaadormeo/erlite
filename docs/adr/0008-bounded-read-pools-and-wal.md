# ADR 0008: Bounded SQLite read pools and WAL

## Status

Accepted

## Context

A replica previously executed standalone SQL reads on the same Erlang process
and SQLite connection that applies committed Raft writes. A slow read could
therefore occupy the authoritative write owner even after the consistent-read
barrier and replica catch-up had completed. Multiple SQLite connections also
need an explicit journal-mode policy to support useful read/write concurrency.

## Decision

Each active replica retains exactly one serialized SQLite write owner and adds a
bounded pool of query-only reader connections. A strongly consistent read must
first complete the leader barrier and catch the write owner up through that
index. Only then is its SQL submitted to the reader pool.

The initial pool configuration is global: one reader by default, a maximum of
eight readers, and a bounded FIFO queue of 64 waiting requests by default. When
the queue is full, new reads fail with `read_pool_overloaded`. Normal shutdown
drains accepted work before closing all reader connections. A reader crash fails
accepted work and terminates its write owner so lifecycle state cannot appear
healthy with an incomplete pool.

Every managed write connection enables and verifies SQLite WAL journal mode and
sets and verifies `synchronous=FULL`. Reader connections are opened query-only.
Snapshot creation continues to use `VACUUM INTO` for a standalone image, while
installation and deletion remove obsolete WAL and shared-memory sidecars.

This decision does not add follower reads, cross-database transactions,
multi-writer SQLite, or multi-statement read transactions.

## Consequences

Slow standalone SQL no longer occupies the database controller or serialized
write owner after consistency preparation. Independent reads may execute in
parallel when more than one worker is configured, while process, connection,
memory, descriptor, and queued-work growth remain bounded.

WAL introduces auxiliary `-wal` and `-shm` files and checkpoint behavior. All
file replacement and deletion paths must therefore close the complete pool and
handle those sidecars. `synchronous=FULL` favors durability over maximum write
throughput, consistent with Erlite's correctness priority.
