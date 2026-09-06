# Erlite

Erlite is an Erlang/OTP runtime for operating many independently replicated SQLite databases across a cluster.

The project is being implemented incrementally according to [`ERLITE_PROJECT.md`](ERLITE_PROJECT.md). Phases 0 through 2 now provide the supervised SQLite boundary, replication correctness primitives, persistent node identity and configuration, and a three-member RabbitMQ `ra` cluster catalog.

## Requirements

- Erlang/OTP 29
- rebar3

## Development

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 escriptize
```

The generated command supports `init-cluster`, `join <seed-node>`, `leave`, and `cluster status`. Distributed Erlang naming and cookies must be configured when starting the command VM. Phase 3 will add single-database high availability and consistent data reads; placement, database lifecycle, and the network API remain later roadmap work.
