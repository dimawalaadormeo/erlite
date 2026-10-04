# Migrations

Erlite schemas change only through versioned migrations. A migration is a
replicated Raft command, so every replica applies it in the same order as writes.
Migrations are not available through the HTTP API. Applications apply them
through Erlang on a cluster node or over an authenticated Erlang distribution
connection.

## Model

- Each database has a `schema_version`, starting at `0` for a new database.
- A migration has a set name, a migration ID, `from` and `to` versions, and
  statements. `to` must be `from + 1`, so versions advance one step at a time.
- Each migration is recorded in the database's migration history with its
  command hash. The same set and ID with the same content is idempotent. The
  same ID with different content is a conflict.
- A migration whose `from` version does not match the current version is
  durably rejected. The schema does not change, and the applied index advances.
- Application and module migrations use the same representation. Explicitly
  scoped database migrations do too.
- Current `schema_version` is returned by `GET /v1/databases/{id}`.

## Statement policy

The migration policy permits tables, ordinary indexes, and `ALTER`/`DROP`
forms. It rejects:

- multiple statements
- internal Erlite objects
- triggers, views, and virtual tables
- collations, defaults, and generated, time, or random expressions
- data manipulation (`INSERT`, `UPDATE`, `DELETE`)

The same validator runs when the migration enters Raft and again before SQLite
applies it.

## Applying a migration to one database

From an Erlang node or a distribution connection to a cluster node:

```erlang
{ok, Command} = erlite_raft_command:new_migration(
    <<"app">>, <<"001-products">>, 0, 1,
    [{<<"CREATE TABLE products(sku TEXT PRIMARY KEY, name TEXT)">>, []}]),
{ok, Index} = erlite_databases:migrate(<<"merchant-100">>, Command, 15000).
```

`Index` is the committed Raft index. Afterward, `schema_version` is `1`.

## Applying a migration to many databases

`erlite_fleet_migrations` runs a migration across a fleet. It records campaign
state in the catalog, and it runs a canary cohort before bounded batches. It
supports pause and resume, retries, and progress reports. A canary failure
pauses the campaign. See the example in [`user-guide.md`](user-guide.md).

```erlang
Migrations = [#{id => <<"create-orders">>, from => 0, to => 1,
                statements =>
                    [{<<"CREATE TABLE orders (id INTEGER PRIMARY KEY)">>, []}]}],
{ok, CampaignId} = erlite_fleet_migrations:start(
    <<"sales-app">>, Migrations,
    #{databases => DatabaseIds, canary_size => 1,
      batch_size => 25, max_retries => 3,
      idempotency_key => <<"sales-v1-rollout">>}).
```

## Failure behavior

- A deterministic SQLite error during a migration is recorded durably. The
  schema and version do not change, and a fleet canary pauses.
- Transient failures, such as disk full, busy, or locked, are not recorded. The
  applied index does not advance, and application retries once the fault clears.
- Rollback is forward-only. Undo a change with a new migration that moves the
  version forward.

## Not yet available

- No HTTP route creates or applies migrations.
- No command-line tool or migration-file format exists yet for ordered,
  checksummed migration files.

Tooling for these gaps is not yet scheduled; it will be added to the plan after
the current changes merge.
