# ADR 0002: Catalog-fenced automatic replica repair

- Status: Accepted
- Date: 2026-09-08

## Context

An RF=3 database remains writable with two reachable members, but it must not
remain under-replicated indefinitely. A failed member cannot be used as the
Phase 7 movement snapshot source, and its local Ra and SQLite state may return
after the membership has changed.

## Decision

A supervised repair worker periodically checks the catalog's ready databases.
A replica is healthy only when its Erlang node is reachable and its named Ra
server is running. Exactly one failed replica is recorded durably in the
catalog with an operation ID and wall-clock detection time. Recovery before
the configurable grace period clears that record.

After the grace period, an active, reachable node outside the database's
placement is selected. The catalog atomically converts the repair record into
a repair-kind movement, mutually excluding manual movement and deletion. The
physical mover takes its verified snapshot from either surviving member, adds
and catches up the replacement, verifies its SQLite applied index, commits
removal of the failed member through the healthy quorum, and then advances the
placement generation.

The removed server is recorded as a stale replica even when it was unreachable
during removal. Catalog routing never includes it. When its node returns, the
repair worker deletes its old Ra server and SQLite image before clearing the
stale record. Stale cleanup also runs for deleting and tombstoned databases.

No repair begins with fewer than two healthy replicas or without an eligible
target. Such databases remain durably marked and are retried without reducing
membership.

## Consequences

- Repair reuses the verified movement protocol instead of introducing a
  second membership mechanism.
- Detection timestamps and operation identity survive worker restarts.
- Multiple workers converge on one catalog-fenced repair operation.
- Node reachability and Ra-process liveness are the Phase 8 health signal.
