# Erlite Agent Instructions

Read `ERLITE_PROJECT.md` before making architectural changes.

The project source of truth is:

- `ERLITE_PROJECT.md`
- `docs/architecture.md`
- `docs/correctness.md`
- accepted ADRs under `docs/adr/`

## Mission

Build Erlite incrementally.

Erlite is a distributed Erlang/OTP runtime for operating many independently replicated SQLite databases.

Do not turn it into a general-purpose distributed SQL engine.

## Core technical constraints

- Use Erlang/OTP.
- Use RabbitMQ `ra`; never implement Raft.
- SQLite is the storage engine.
- The database is the unit of placement and replication.
- One database may initially correspond to one Raft group.
- Raft log ordering is authoritative for writes.
- SQLite replicas must durably track applied Raft indexes.
- Operations must be idempotent.
- No cross-database transactions.
- Do not introduce `riak_core`.
- Do not rely solely on `ra` side effects for durable database replication.
- Keep SQLite behind an adapter boundary.
- A real 3-node deployment is a basic product requirement.
- Horizontal scale-out must occur by adding Erlite nodes and moving independent database replicas.
- Automatic repair of under-replicated databases is a core capability.
- Future offline/edge mode must use explicit synchronization, never bypass Raft quorum.

## Working method

Work on one roadmap item at a time.

Before coding:

1. Read relevant project documentation.
2. Inspect existing implementation.
3. State the invariant the change must preserve.
4. Make the smallest coherent implementation.

After coding:

1. Compile.
2. Run relevant unit tests.
3. Run relevant integration tests.
4. Report exactly what was executed.
5. Update documentation if behavior changed.

Never claim a test passed unless it was actually executed successfully.

## Correctness priority

For replication, recovery, membership, backup, migration, repair, or rebalancing:

**correctness > recoverability > simplicity > performance > convenience**

Any change affecting replication correctness must update `docs/correctness.md`.

Any long-term architectural decision should receive an ADR.

## Cluster MVP requirements

Baseline requirements:

- `erlite init-cluster`
- `erlite join <seed>`
- `erlite leave`
- `erlite cluster status`
- persistent node identity
- 3-node catalog group
- default RF=3
- quorum=2
- database create/list/delete/status
- leader election
- follower catch-up
- refusal of consistent writes without quorum

Do not consider the cluster MVP complete until a real three-node failure test passes.

## Horizontal scaling requirements

Erlite scales primarily across independent databases.

Do not attempt to make one SQLite database horizontally multi-writer.

When adding nodes:

1. choose safe replica movements;
2. add replacement replica;
3. catch it up;
4. verify it;
5. change Raft membership;
6. only then remove the old replica.

Rebalancing must be incremental and throttled.

## Replica repair requirements

For RF=3 databases that fall to 2 healthy replicas:

1. mark database under-replicated;
2. wait for configurable repair grace period;
3. choose replacement node;
4. bootstrap replacement;
5. catch it up;
6. verify applied index;
7. perform safe membership transition;
8. remove failed member from active membership;
9. safely handle stale replicas if the old node returns.

Never reduce healthy redundancy further while repairing.

## Migration requirements

Each database may have its own migration history.

Support:

- base schema versions
- optional module migration sets
- tenant-specific migrations when explicitly required

Fleet migrations should eventually support:

- batching
- canary rollout
- pause/resume
- retries
- progress reporting

Avoid uncontrolled schema divergence.

## Scope discipline

Do not implement future roadmap features while completing an earlier phase unless required for correctness.

Avoid speculative abstractions.

Prefer small, reviewable patches.

## Test expectations

Use EUnit for local module behavior.

Use Common Test for cluster behavior.

Failure tests should eventually cover:

- leader crash
- follower crash
- restart
- duplicate delivery
- delayed SQLite application
- network interruption
- node replacement
- schema migration
- replica catch-up
- quorum loss
- node join/leave
- database migration
- rebalance interruption
- automatic replica repair
- failed repair
- stale-node return

When fixing a bug, add a regression test whenever practical.

## Commands

At minimum expect:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

Run Dialyzer when configured and relevant.

## Git

Keep commits narrow.

Do not combine unrelated refactors with feature work.

Do not rewrite history or force-push unless explicitly instructed.

## Completion rule

A roadmap task is complete only when:

- implementation exists
- tests exist
- tests pass
- failure behavior is understood
- relevant documentation is updated
