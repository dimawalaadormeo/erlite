# Erlite

@ERLITE_PROJECT.md

Treat `ERLITE_PROJECT.md` as the primary project specification.

Also consult:

- `docs/architecture.md`
- `docs/correctness.md`
- `docs/adr/`

## Working approach

For substantial changes, explore existing code and produce a plan before editing.

Work incrementally.

Do not attempt to implement the entire roadmap in one session.

Use subagents when useful for isolated investigation such as:

- studying `ra` APIs
- checking SQLite behavior
- reviewing failure semantics
- reviewing cluster bootstrap
- reviewing node identity behavior
- reviewing database migration/rebalancing
- reviewing automatic replica repair
- reviewing fleet migrations
- reviewing tests
- investigating performance

The main agent remains responsible for integrating conclusions.

## Architectural rules

Erlite is a multi-database runtime, not a single globally distributed SQLite database.

Use Erlang/OTP and RabbitMQ `ra`.

Never implement custom Raft.

Never introduce `riak_core` without an explicit architecture decision approved by the project owner.

SQLite is the local materialized database.

The committed Raft log establishes write order.

Each SQLite replica must durably track which Raft entries it has applied.

Replication and recovery must be idempotent.

Do not rely on fire-and-forget side effects as the only durability mechanism.

Do not implement cross-database transactions.

Keep SQLite/NIF-specific code behind an adapter.

A real three-server cluster is part of the basic product.

Horizontal scaling is accomplished by adding Erlite nodes and redistributing independent database replicas.

Do not try to turn one SQLite database into a multi-writer distributed SQL database.

Automatic repair of under-replicated databases is part of the core design.

Future edge/offline mode must use explicit synchronization and must not bypass Raft quorum rules.

## Basic cluster requirements

The baseline implementation must support:

- `erlite init-cluster`
- `erlite join <seed>`
- `erlite leave`
- `erlite cluster status`
- persistent node identity
- RF=3 by default
- quorum=2 for three-member groups
- cluster catalog
- database create/list/delete/status
- automatic leader election
- follower catch-up
- refusal of consistent writes without quorum

## Horizontal scaling rules

When adding a node, database movement must be safe and incremental.

For each move:

1. add new replica;
2. catch it up;
3. verify it;
4. change Raft membership;
5. remove old replica.

Never remove the old replica first.

Rebalancing safety is more important than perfect load balance.

## Replica repair rules

When a database loses a replica but still has quorum:

1. mark it under-replicated;
2. wait through a configurable grace period;
3. choose a replacement node;
4. bootstrap and catch up the replacement;
5. verify applied state;
6. perform safe Raft membership change;
7. retire the failed member;
8. safely handle stale replicas if the failed node returns.

The catalog and Raft membership are authoritative.

## Migration rules

Support per-database migration history.

Prefer:

- common base schema
- named module migration packs
- tenant-specific migrations only when genuinely necessary

Fleet migrations should eventually support:

- canary rollout
- batching
- pause/resume
- retries
- progress reporting

## Priority

When tradeoffs arise:

**correctness  
then recoverability  
then simplicity  
then performance  
then convenience**

Distributed-database code that works only on the happy path is incomplete.

## Validation

Before finishing a coding task:

- compile the project
- run relevant EUnit tests
- run relevant Common Test suites
- inspect failures rather than bypassing them
- update documentation where semantics changed

State which commands actually ran.

Do not say a test passed unless it passed.

## Documentation

Replication changes must update `docs/correctness.md`.

Cluster membership/bootstrap changes should update `docs/clustering.md`.

Scaling/rebalancing changes should update `docs/scaling.md`.

Migration changes should update `docs/migrations.md`.

Architectural decisions should be recorded under `docs/adr/`.

Keep documentation synchronized with code.

## Scope

Implement only the current roadmap phase unless a later capability is strictly required for correctness.

Prefer small, reviewable commits.

Do not perform large opportunistic refactors during feature implementation.
