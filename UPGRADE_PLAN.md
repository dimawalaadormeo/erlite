# Erlite Upgrade Plan

## Read-worker upgrade

### Current status

Phases 2 through 4 are implemented: every active replica has a bounded configurable
query-only reader pool, and standalone reads are dispatched after the existing
leader barrier and catch-up without occupying the database controller or SQLite
write owner. The default is one reader with 64 waiting requests per replica;
reader count is capped at eight. Reader resource accounting is exposed in
database status. Write connections enable and verify WAL mode with
`synchronous=FULL`; read workers remain query-only connections to that WAL
database.

### Goal

Move standalone read-only SQL execution away from the serialized SQLite write
owner. This should prevent slow reads from occupying the process responsible
for applying committed Raft writes and should allow configurable concurrent
reads per active database replica.

This upgrade does not add follower reads, cross-database transactions, or a
multi-writer SQLite design.

## Correctness invariants

- The Raft log remains the authoritative ordering of writes.
- Each replica continues to use one serialized SQLite write owner for applying
  committed Raft commands and updating its durable applied index.
- A strongly consistent read completes a quorum-confirmed Raft barrier and
  catches the leader's write owner up through that barrier before executing SQL.
- Read workers are query-only. They cannot apply Raft commands, update Erlite's
  internal metadata, run migrations, or create snapshots.
- A read-only transaction, if supported later, remains pinned to one reader
  connection for its entire lifetime.
- Cooling, deletion, restore, snapshot installation, and replica replacement
  close all read connections before changing or removing the SQLite file.

## Proposed initial scope

1. Keep the existing single write owner and connection per SQLite replica.
2. Add a supervised pool of query-only read workers per active replica.
3. Route standalone strongly consistent reads to the leader's read-worker pool
   only after the existing barrier and catch-up path succeeds.
4. Select workers using a small deterministic policy such as round-robin.
5. Make the pool size configurable and bounded.
6. Preserve current API behavior and error semantics where practical.

The initial version should not include follower reads or multi-statement
read-only transactions. Those require separate consistency and connection
pinning designs.

## Recorded implementation decisions

- Read-worker configuration is global initially: one worker by default, capped
  at eight, with a default bounded FIFO queue of 64 requests per replica.
- Writer opens enable and verify WAL mode and `synchronous=FULL`. Separate
  Erlang processes alone do not remove SQLite file-lock contention.
- When every reader and queue slot is occupied, reject new work with
  `read_pool_overloaded`.
- Define query timeouts and cancellation behavior.
- Decide whether cold databases start readers eagerly on activation or lazily
  on the first read.
- Include reader processes, connections, memory, and file descriptors in
  resource accounting and observability.

## Implementation phases

### Phase 1: establish a baseline

- Measure current read concurrency, write delay during slow reads, memory, and
  file-descriptor usage.
- Add a regression test demonstrating that a long read currently occupies the
  serialized owner.
- Record expected consistency and failure behavior.

### Phase 2: introduce one separate reader

- Add a query-only SQLite reader process behind the adapter boundary.
- Supervise it as part of the replica lifecycle.
- Dispatch standalone reads to it after leader barrier and catch-up.
- Close it safely during cooling, deletion, restore, and replacement.

This phase proves isolation from the write owner before introducing pooling.

Status: implemented.

### Phase 3: add a bounded reader pool

- Add configurable pool sizing and worker selection.
- Ensure concurrent requests do not serialize through a dispatcher while SQL is
  running.
- Define bounded queueing and timeout behavior.
- Expose worker and queue utilization without database IDs in metric labels.

Status: implemented for pool sizing, bounded queueing, worker utilization, and
per-database status accounting. Aggregate metric counters remain future work.

### Phase 4: evaluate SQLite concurrency mode

- Test read/write contention with the current journal mode.
- Evaluate WAL mode, checkpoint behavior, backup interaction, snapshot safety,
  and auxiliary-file cleanup.
- Adopt WAL only after its lifecycle and recovery behavior are covered by tests
  and documented in the correctness model.

Status: implemented. Writer creation and reopen verify WAL mode and FULL
synchronous durability. Existing snapshot/install and cleanup paths continue to
produce standalone snapshots and remove WAL sidecars when replacing or deleting
database files.

### Phase 5: consider later read modes

- Design explicitly requested read consistency levels.
- Consider follower or local reads only with a clear staleness contract and an
  applied-index readiness check.
- Design connection pinning separately before supporting multi-statement
  read-only transactions.

### Performance validation

An opt-in three-container, single-host benchmark is implemented under
`tools/read-benchmark`. It compares 1, 2, 4, and 8 reader workers using mixed
quorum-backed reads and writes, recording latency distributions, errors,
resource usage, pool status, and WAL growth. Its results are comparative and
must not be presented as multi-host production capacity measurements.

The extended workload matrix adds large seeded tables, point reads, range
aggregates, recursive CPU-heavy reads, a write-heavy profile, and explicit WAL
checkpoint measurements. Its purpose is to identify workload-specific reasons
to increase the pool and to gather evidence before setting checkpoint policy.

Status: completed on the single-host three-container topology. One reader
remains the general default; four readers are recommended only for databases
with measured concurrent CPU-heavy reads. Passive checkpoints completed without
busy frames, but the run is too short to set an explicit checkpoint threshold.

## Test plan

### Unit tests

- Reader connections reject writes at the SQLite layer.
- Worker selection uses the configured bounded pool.
- A reader failure is contained and recovered according to supervision policy.
- Pool shutdown closes every SQLite connection.
- Invalid pool configuration fails safely or uses a documented default.

### Integration tests

- A strongly consistent read observes a write acknowledged before the read.
- A slow read does not occupy the SQLite write-owner process.
- Concurrent reads execute across multiple workers.
- Quorum loss still prevents strongly consistent reads.
- Cooling and reactivation rebuild the pool safely.
- Delete, restore, snapshot installation, replica movement, and repair do not
  leave live readers attached to replaced or deleted files.
- Leader changes preserve barrier and catch-up guarantees.

### Required validation

Run and report the exact results of:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

Relevant three-node failure tests and scale/resource tests must also pass before
the upgrade is considered complete.

## Completion criteria

- Standalone reads execute outside the serialized write owner.
- Strong-read semantics remain unchanged.
- Reader concurrency is bounded and configurable.
- Lifecycle and failure behavior are tested and understood.
- Resource impact is measured and remains within an accepted budget.
- `docs/architecture.md` and `docs/correctness.md` describe the final behavior.
- No follower-read or transaction-pinning behavior is implied unless it has
  been separately designed and implemented.
