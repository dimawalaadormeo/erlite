# Erlite

Erlite is an Erlang/OTP runtime for operating many independently replicated SQLite databases across a cluster.

The project is being implemented incrementally according to [`ERLITE_PROJECT.md`](ERLITE_PROJECT.md). Phases 0 and 1 now provide the supervised SQLite boundary plus a three-member RabbitMQ `ra` correctness spike with deterministic commands, durable external application, restart catch-up, and verified SQLite snapshots.

## Requirements

- Erlang/OTP 29
- rebar3

## Development

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

Phase 1 is a correctness spike, not a production database service. Cluster bootstrap, placement, a catalog, real three-node deployment, and the network API remain later roadmap work.
