# ADR 0007: Hardening admission and failure semantics

- Status: accepted
- Date: 2026-09-10

## Context

Rolling replacement can introduce a node that cannot interpret the active
protocol or durable formats. Separately, a deterministic DDL error after Raft
commit can otherwise leave an entry that fails forever and blocks all later
SQLite application. Resource failures must not be confused with that outcome.

## Decision

Before persistent join work, Erlite compares release metadata with the seed.
Supported cluster-protocol ranges must overlap, while command format, snapshot
format, and canonical SQLite runtime identity must match exactly.

SQLite errors determined by replicated command content or schema are treated
as deterministic failed commands. For transactions this includes ordinary
constraint, type mismatch, oversized-value, and SQL errors; migrations admit
deterministic DDL errors. The replica atomically records the command identity,
hash, Raft index, and error and advances its applied index without committing
user mutations. Migration failures also leave schema version unchanged. The
request still fails and a canary failure pauses the fleet campaign. Busy,
locked, storage, I/O, corruption, interruption, and resource errors are not
converted into failed commands: the applied index remains unchanged until
retry succeeds.

Liveness remains independent of quorum. Readiness requires supervised core
workers and a consistent catalog result with three active members. Metric keys
are fixed atoms and never contain database or client identifiers.

## Consequences

- Compatible rolling releases can replace nodes incrementally; incompatible
  releases require a future explicit format-upgrade protocol.
- Deterministically rejected transactions and migration DDL do not poison
  subsequent Raft application; failed migration schema version stays unchanged.
- Disk-full behavior remains fail-closed and recoverable after capacity is
  restored.
- Readiness drops during catalog partitions even while liveness remains up.
