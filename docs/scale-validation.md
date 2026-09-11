# Phase 14 scale validation

Phase 14 is an acceptance exercise, not a change to Erlite's replication
semantics. A scale result is valid only when every measured database retains
RF=3, quorum writes, durable SQLite applied indexes, and the existing fenced
movement and repair protocols.

## Staged local gate

`erlite_phase14_scale_SUITE` provisions real databases through the catalog
lifecycle and creates three real Ra members and SQLite replicas for every
database. It measures whole-VM memory and process growth, file descriptors,
ports, reductions, context switches, disk growth, provisioning latency, and a
sample of quorum-backed query latency. Sampled status also separates controller,
SQLite-owner, and primary Ra-server process memory. Results are emitted as a versioned
Erlang term in the suite's temporary storage root and printed in the Common
Test log.

The suite is opt-in so a normal test run cannot accidentally allocate the
resources required by a scale milestone:

```bash
ERLITE_SCALE_DATABASES=1000 rebar3 ct \
  --suite=apps/erlite_core/test/erlite_phase14_scale_SUITE.erl
ERLITE_SCALE_DATABASES=5000 rebar3 ct \
  --suite=apps/erlite_core/test/erlite_phase14_scale_SUITE.erl
ERLITE_SCALE_DATABASES=10000 rebar3 ct \
  --suite=apps/erlite_core/test/erlite_phase14_scale_SUITE.erl
```

The local gate deliberately labels its topology as
`single_vm_three_ra_members`. It must not be cited as a three-server network
result. Counts of 10,000 or higher are accepted for the final `10,000+`
milestone.

## Required distributed run

The roadmap is complete only after the same release is exercised on at least
three separate Erlite nodes (and a fourth node for movement/rebalancing), with
the host specification and Erlang VM flags recorded. At 1,000, 5,000, and
10,000+ databases, retain the local report fields and additionally record:

- read and committed-write latency distributions under a stated concurrency;
- leader failover latency while writes continue;
- restarted-follower Ra and SQLite catch-up time and backlog size;
- verified replica-movement throughput to the fourth node;
- per-host CPU, resident memory, file descriptors, and disk bytes;
- per-interface bytes sent and received, with background traffic excluded;
- workload duration, success/failure counts, and quorum/readiness state.

Failover timing starts immediately before terminating the selected leader and
ends at the first successful post-election committed write. Catch-up ends only
after both the Ra barrier and SQLite durable applied index are verified.
Rebalance throughput counts only movements that completed the add, catch-up,
verification, membership transition, and source-retirement sequence.

Every report must state topology, hardware, operating system, filesystem,
OTP/Erlite versions, database count, RF, workload, warm-up, sample count, and
raw result location. A failed or interrupted milestone remains a result; it
must not be silently extrapolated to a larger count.

## Acceptance state

The checked-in suite makes the local resource gate reproducible. All three
local milestones have run; Phase 14 remains in progress until the distributed
failure, catch-up, network, and rebalance measurements above have actually
run. This document should be extended with dated distributed result summaries
and links to retained raw reports after each accepted run.

### 2026-09-11 local staged results

The 1,000, 5,000, and 10,000 tiers passed on OTP 29.0.3, Linux
7.0.0-31-generic, ext4, and an
8-core/16-thread AMD Ryzen 7 8845HS host. The descriptor limit was 1,048,576.
This was the suite's explicitly limited single-VM topology, with all three Ra
members local, no concurrent client load, and 100 sampled queries.

| Measurement | 1,000 | 5,000 | 10,000 |
| --- | ---: | ---: | ---: |
| Provision mean / p95 / p99 (ms) | 64.171 / 70.521 / 72.970 | 71.001 / 82.165 / 86.448 | 80.521 / 104.101 / 112.536 |
| Query mean / p95 / p99 (ms) | 0.313 / 0.524 / 0.564 | 0.257 / 0.351 / 0.605 | 0.328 / 0.494 / 0.560 |
| Whole-VM memory growth (bytes) | 575,904,376 | 2,673,067,616 | 5,230,367,776 |
| Memory per database (bytes) | 575,904 | 534,613 | 523,036 |
| Erlang process growth | 13,000 | 65,000 | 130,000 |
| File-descriptor growth | 3,001 | 15,024 | 30,067 |
| Logical disk growth (bytes) | 136,848,209 | 684,167,737 | 1,368,299,895 |

Each run completed every lifecycle create, 100 sampled consistent queries, and
durable lifecycle cleanup. These local runs do not satisfy the distributed
write, failover, catch-up, rebalance, CPU-utilization, or network portions of
Phase 14.
