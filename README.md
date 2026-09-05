# Erlite

Erlite is an Erlang/OTP runtime for operating many independently replicated SQLite databases across a cluster.

The project is being implemented incrementally according to [`ERLITE_PROJECT.md`](ERLITE_PROJECT.md). The current Phase 0 implementation contains the initial supervised OTP application, a backend-neutral SQLite adapter contract, a file-backed `esqlite` adapter, and safe local database-file lifecycle operations.

## Requirements

- Erlang/OTP 29
- rebar3

## Development

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

The database lifecycle, replication, and network API will be added as separate roadmap tasks. No production-ready database service is available yet.
