# API token hardening plan

Status: implemented, except where noted below. Final behaviour is recorded in
`docs/correctness.md` (API token store). Two review findings on the API token store.
Read `docs/correctness.md` (API token store) first.

## Findings

**P0. Token store admits a protocol-1 catalog member.**

- `erlite_api_tokens:enable/0` checks live releases only for nodes in `active`
  state ([erlite_api_tokens.erl:41](../apps/erlite_core/src/erlite_api_tokens.erl)).
- A protocol-1 node can still be `joining` when that check runs. After enablement
  commits, `activate_node` promotes it without checking its release
  ([erlite_catalog_machine.erl:38](../apps/erlite_catalog/src/erlite_catalog_machine.erl)).
- The protocol check exists only in `prepare_join`
  ([erlite_catalog_machine.erl:248](../apps/erlite_catalog/src/erlite_catalog_machine.erl)).
  It is not a startup fence, so a member restarted or rolled back to protocol 1
  after enablement is not stopped.
- An old machine does not understand token commands, so replicas can apply the
  same Raft entries differently.

**P1. Invalid bearer tokens force consistent catalog reads.**

- After static credentials miss, `erlite_api_server` calls catalog-backed
  authentication on every request
  ([erlite_api_server.erl:231](../apps/erlite_core/src/erlite_api_server.erl)).
- A random token gets a local miss, then a consistent quorum read with a 5 s
  timeout ([erlite_api_tokens.erl:93](../apps/erlite_core/src/erlite_api_tokens.erl)).
- An unauthenticated client can turn cheap HTTPS requests into consensus traffic.

## P0 plan: token-store protocol floor

Goal: once the token store is on, no node below protocol 2 can become a catalog
member, activate, or count as healthy.

1. **Durable floor in the machine.** Add `min_protocol` to the catalog machine
   state. `enable_token_store` sets it to 2. It is replicated, so every replica
   holds the same value.
2. **Enforce on activation.** `activate_node` refuses a node whose stored release
   is below the floor, returning `cluster_protocol_too_old_for_token_store`. This
   closes the join/enable race: a protocol-1 node still `joining` when enable runs
   cannot be promoted afterwards.
3. **Enable checks every member.** Live release checks cover `joining` and
   `leaving` nodes as well as `active` ones. The machine's enable command also
   re-checks stored releases for all non-removed nodes.
4. **Stored release updates respect the floor.** `update_release` refuses a
   protocol below the floor once the token store is on.
5. **Startup fence.** Not implemented. Every new binary already reports protocol 2,
   so a startup check could only fire on a misbuilt binary. The enforcement that
   matters is in steps 1 to 4, and the cases an old binary can create are covered
   by the limit below.

**Known limit.** New code cannot stop an old binary that is already running, or
one that is rolled back. Old code neither runs these checks nor reports its
release. The cluster can refuse to count such a node, but it cannot stop the node
from running. Until the live audit in step 6 exists, the rule is operational:
never downgrade a node below the enabled floor.

6. **Follow-up: live release audit.** The catalog leader periodically checks each
   active node's live release. A mismatch marks the node unhealthy and removes it
   from routing and placement. This is not part of the first change.

Tests:

- Machine: `activate_node` refused below the floor; `update_release` refused
  below the floor; enable re-checks stored releases.
- Race regression: a protocol-1 node in `joining` while enable runs. Enable must
  refuse, or activation must refuse once enable has committed.
- Common Test: join during enable, and a rollback where the stored record says
  protocol 2 but live metadata says 1.

## P1 plan: invalid bearer tokens

Goal: an unauthenticated client cannot turn HTTPS requests into quorum reads.

A follower's local replica cannot make a negative lookup authoritative. Its view
of the commit index can be stale, so a local miss may be a token issued elsewhere.
Misses therefore must not depend on the local replica or on a quorum read for
every request.

1. **Per-source failed-auth limiter.** A token bucket counts failed bearer lookups
   per source address. An exhausted bucket returns `429` before any catalog work.
2. **Bulkhead for consistent token reads.** Cap concurrent consistent token reads.
   Excess requests get `503` immediately, without consensus traffic.
3. **Shorter negative timeout.** Use 1 s on the negative path instead of 5 s. A
   timeout is refused, not retried.
4. **Counters.** Add bounded counters for negative lookups, limiter rejections,
   bulkhead rejections, and timeouts to `/v1/metrics`. No per-token labels.
5. **No negative cache.** Random invalid tokens do not repeat, so a cache gives
   no benefit, and a cached negative could refuse a token issued moments earlier.

Limiter values as implemented: 10 failures per source per second, a global cap of
200 per second, 32 concurrent consistent token reads, and a 1 s timeout on the
negative path. A valid token found on the local replica is never charged.

Tests:

- EUnit: token bucket and bulkhead behaviour.
- Common Test: a flood of random tokens must not raise consistent reads above the
  cap, and valid tokens must still succeed during the flood.

Measurement: rerun the netem benchmark with an invalid-token flood. Report
catalog reads per second, `429` and `503` rates, and valid-token latency during
the flood.

## Documentation

- `docs/correctness.md`: the protocol floor, the rollback limit, and the
  negative-path limits.
- `docs/api-reference.md`: the new `429` and `503` responses for authentication.

## Validation

Before the change is reported as done:

- `rebar3 compile`
- `rebar3 eunit`
- The token-related Common Test cases

Report only the results that actually ran.

## Deviations and follow-ups

- Step 5 (startup fence) is not implemented, for the reason given above.
- The live release audit (P0 step 6) is not implemented. It is a known gap until
  it is built.
- Unknown tokens on a node with no catalog now return `503`, not `401`, because the
  server cannot confirm them. A request with no `Authorization` header still
  returns `401`.
