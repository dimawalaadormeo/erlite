# Erlite

Erlite is an Erlang/OTP runtime for operating many independently replicated SQLite databases across a cluster.

The project is being implemented incrementally according to [`ERLITE_PROJECT.md`](ERLITE_PROJECT.md). Phases 0 through 3 now provide the supervised SQLite boundary, replication correctness primitives, persistent node identity and configuration, a three-member RabbitMQ `ra` cluster catalog, and single-database high availability with quorum-confirmed reads and writes.

## Requirements

- Erlang/OTP 29
- rebar3
- a POSIX `sync` utility supporting `sync -d` for durable checkpoint publication

## Development

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 escriptize
```

The generated command supports `init-cluster`, `join <seed-node>`, `leave`, and `cluster status`. Distributed Erlang naming and cookies must be configured when starting the command VM. Phase 4 will add multiple-database lifecycle and placement; transparent routing and the network API remain later roadmap work.
