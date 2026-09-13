# Three-container read benchmark

This opt-in harness compares Erlite read-pool sizes on three Erlite nodes in
separate containers on one machine. It exercises real Erlang distribution,
three catalog members, one RF=3 database per pool size, quorum-backed consistent
reads, and replicated writes.

Run:

```sh
tools/read-benchmark/run.sh
```

Override workload parameters with `ERLITE_BENCH_DURATION_SECONDS`,
`ERLITE_BENCH_CONCURRENCY`, `ERLITE_BENCH_QUEUE_LIMIT`,
`ERLITE_BENCH_READERS`, or `ERLITE_BENCH_WRITE_PERCENT` in `compose.yml`, or
pass them to `docker compose run -e NAME=value benchmark`.

`ERLITE_BENCH_SEED_ROWS` controls the identical unmeasured data seed applied to
all three replicas. `ERLITE_BENCH_PROFILES` selects point lookups, range
aggregates, recursive CPU-heavy reads, and an 80%-write workload. Every variant
also records a passive WAL checkpoint duration and before/after WAL sizes.

The versioned raw report is written to `tools/read-benchmark/results/`. It
contains read and write latency percentiles, error counts (including pool
overload), per-node VM and descriptor measurements, database/WAL/SHM sizes, and
database pool status. Each variant also checks cooling/reactivation, standalone
snapshot creation, follower-loss writes, leader failover, and server restart.
Use `docker compose -f tools/read-benchmark/compose.yml
down -v` to remove the benchmark containers and volumes.

These results are comparative single-host measurements. Shared CPU, storage,
and the container bridge mean they are not production capacity or multi-host
network claims. Run one benchmark at a time on an otherwise idle host and retain
the host specification with every accepted report.

The first retained comparison and its recommendation are in
`RESULTS_2026-09-13.md`; its complete machine-readable source is
`results/read-benchmark.term`.
