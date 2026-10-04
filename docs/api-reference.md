# Erlite HTTP API Reference

This is the complete reference for Erlite's HTTP/JSON API. It covers every
endpoint, authentication, request and response shapes, error handling, limits,
and task-based guides with working samples.

Erlite exposes this API only when the `api` section of `erlite_core` is
enabled. The service speaks HTTP/1.1 over TLS. Every connection carries one
request and is closed after its response.

Contents:

1. [Quickstart](#1-quickstart)
2. [Configuration and TLS](#2-configuration-and-tls)
3. [Authentication and authorization](#3-authentication-and-authorization)
4. [Request format](#4-request-format)
5. [Response format and status codes](#5-response-format-and-status-codes)
6. [Endpoint reference](#6-endpoint-reference)
7. [Query SQL policy](#7-query-sql-policy)
8. [Transaction statements and values](#8-transaction-statements-and-values)
9. [Timeouts and retries](#9-timeouts-and-retries)
10. [Limits](#10-limits)
11. [Guides](#11-guides)

---

## 1. Quickstart

Check the service is up (no token required):

```bash
curl --cacert /etc/erlite/tls/ca.crt https://erlite.example:8443/v1/health
```

```json
{"status":"ok"}
```

Create a database (admin token required):

```bash
curl --cacert /etc/erlite/tls/ca.crt \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_id":"merchant-100"}' \
  https://erlite.example:8443/v1/databases
```

```json
{"status":"ok"}
```

Run a read (service token scoped to `merchant-100`):

```bash
curl --cacert /etc/erlite/tls/ca.crt \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sql":"SELECT name FROM products WHERE sku = ?","params":["ABC1"]}' \
  https://erlite.example:8443/v1/databases/merchant-100/query
```

```json
{"result":{"columns":["name"],"rows":[["Product"]]}}
```

Run a replicated write:

```bash
curl --cacert /etc/erlite/tls/ca.crt \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "transaction_id": "sale-2026-10-04-0001",
        "schema_version": 1,
        "statements": [
          {"sql": "INSERT INTO products(sku, name) VALUES(?, ?)",
           "params": ["ABC2", "Widget"]}
        ]
      }' \
  https://erlite.example:8443/v1/databases/merchant-100/transactions
```

```json
{"result":42}
```

The `result` value is the Raft log index that committed the write.

This quickstart assumes `merchant-100` already has a `products` table created by
a migration, and that its `schema_version` is 1. See
[Transaction statements and values](#8-transaction-statements-and-values).

---

## 2. Configuration and TLS

The listener is configured in the `erlite_core` application environment:

```erlang
{api, #{enabled => true,
        port => 8443,
        certfile => "/etc/erlite/tls/server.crt",
        keyfile => "/etc/erlite/tls/server.key",
        credentials =>
            [#{token => <<"replace-with-at-least-32-random-bytes">>,
               role => admin},
             #{token => <<"another-at-least-32-byte-random-secret">>,
               role => service,
               databases => [<<"merchant-100">>]}]}}
```

- The listener is disabled unless `enabled => true`.
- TLS is mandatory. Plain HTTP is not served.
- Certificates should come from your PKI. Clients verify the server certificate;
  do not disable verification.
- Tokens shorter than 32 bytes, and malformed credential records, never
  authenticate.
- Replacing the `credentials` list rotates tokens for new connections.

---

## 3. Authentication and authorization

Only `GET /v1/health` and `GET /v1/ready` are unauthenticated. Every other
endpoint requires a bearer token:

```
Authorization: Bearer <token>
```

Each token has exactly one role, and a role does one kind of work. The two roles
never overlap:

| Role | Allowed | Refused |
| --- | --- | --- |
| `admin` | control operations: list the catalog, create and delete databases, read metrics | every data operation (status, query, transaction) |
| `service` | data operations on the databases in its `databases` list, or all with `databases => all` | every control operation |

Data operations are: reading database status, consistent queries, and
transactions. Control operations are: listing the catalog, creating and deleting
databases, and metrics.

### Token separation

Use a separate token for each job. A typical application needs two:

1. An **admin token**, held by operators or provisioning tooling. It creates the
   database and deletes it. It cannot read or write data.
2. A **service token**, held by the application. It is scoped to the databases
   the application uses. It cannot create or delete databases.

Creating a database and then writing to it takes both tokens, in this order:

```bash
# 1. Admin token: create the database (control operation).
curl -fsS --cacert ca.crt -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_id":"merchant-100"}' https://erlite.example:8443/v1/databases

# 2. Service token scoped to merchant-100: write and read (data operations).
curl -fsS --cacert ca.crt -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sql":"SELECT name FROM products"}' \
  https://erlite.example:8443/v1/databases/merchant-100/query
```

### Managing tokens

Tokens are issued, rotated, and revoked from an Erlang console on a cluster node.
The token store must be enabled once per cluster, after every node has been
upgraded (see [Rolling upgrades](#rolling-upgrades)):

```erlang
ok = erlite_api_tokens:enable().
```

Until then, token commands return `{error, token_store_disabled}`, and only
static configuration credentials authenticate.
They are stored in the replicated catalog as SHA-256 digests, so the server never
holds a plaintext token after it is returned to you. A token is shown once, when
it is issued or rotated.

```erlang
%% One named admin token per operator.
{ok, AdminToken} = erlite_api_tokens:issue_admin(<<"ops-alice">>).

%% One service token per database, for that application.
{ok, ServiceToken} = erlite_api_tokens:issue_service(<<"merchant-100">>).

%% Rotate with a 15-minute grace period: the old token keeps working until then.
{ok, NewToken} = erlite_api_tokens:rotate_service(<<"merchant-100">>, 900000).

%% Rotate with no grace period: the old token stops working at once.
{ok, NewerToken} = erlite_api_tokens:rotate_service(<<"merchant-100">>, 0).

ok = erlite_api_tokens:revoke_admin(<<"ops-alice">>).

erlite_api_tokens:list().   %% names, kinds, and rotation state; never token values

erlite_api_tokens:audit().  %% who-did-what history: operation, key, outcome, time
```

- Deleting a database revokes its service token before the database is removed.
  If revocation fails, the delete does not run.
- Every API request checks the catalog for tokens that are not in the static
  configuration, so a revocation takes effect on the next request.
- Credentials in the static `api` configuration still work during migration. They
  will be removed once the catalog store is the only source.
- Every issue, rotate, revoke, and enable is recorded in the audit history with
  its Raft time and outcome. The history keeps the most recent 1000 entries and
  never contains token values. It does not record which operator ran the command;
  the entry shows the operation, the key, and the time only.
- Each token check reads the catalog with a consistent query. A revoked token
  stops working on the next request on every node.

Using the wrong token fails with `403`:

| Attempt | Result |
| --- | --- |
| Service token creates a database | `403 admin_required` |
| Admin token runs a query or transaction | `403 service_token_required` |
| Service token uses a database outside its list | `403 database_forbidden` |

Authorization failures return `403` with one of these reasons:

- `admin_required` — a control operation was attempted with a service token.
- `service_token_required` — a data operation was attempted with an admin token.
- `database_forbidden` — the token has no access to the requested database.

Authentication failures return `401`:

- `missing_bearer_token` — no `Authorization` header.
- `invalid_bearer_token` — the token matches no configured credential.
- `invalid_credentials_config` — the server's credential configuration is
  malformed.

Application-level authorization (which end user may see which row) is the
application's responsibility. An Erlite token authorizes a *database*, not a
user.

---

## 4. Request format

- **Methods and paths.** Paths are `/v1/...`. Database IDs in paths must be
  percent-encoded if they contain reserved characters.
- **Body.** Requests with a body must send `Content-Type: application/json` and
  a valid `Content-Length`. The body must be a JSON object.
- **Headers.** The total header block is limited to 16 KiB. Duplicate headers,
  negative or non-numeric `Content-Length`, and any `Transfer-Encoding` header
  are rejected with `400`.
- **Keep-alive.** Not supported. Send one request per connection.

---

## 5. Response format and status codes

Successful responses are JSON objects with one of these shapes:

```json
{"status":"ok"}
{"result": <value>}
```

Error responses are JSON objects with an `error` field:

```json
{"error":"database_exists"}
```

When a reason carries detail (for example `{transaction_id_conflict, Id}`), the
`error` value is a JSON array: `{"error":["transaction_id_conflict","sale-1"]}`.
Match on the first element.

### Status codes

| Code | Meaning | Typical `error` values |
| --- | --- | --- |
| 200 | Success | — |
| 400 | Malformed request, missing field, or rejected SQL/value | `invalid_request`, `invalid_json`, `["missing_field", Key]`, `unsafe_query`, `["sqlite_error", Code]`, `["unsupported_replicated_sql", Sql]`, `invalid_database_id` |
| 401 | Missing or invalid bearer token | `missing_bearer_token`, `invalid_bearer_token` |
| 403 | Token lacks the required role or database access | `admin_required`, `service_token_required`, `database_forbidden` |
| 404 | Unknown route or database | `not_found`, `database_not_found` |
| 409 | Conflict with current state | `database_exists`, `["database_not_ready", State]`, `["movement_in_progress", Op]`, `["repair_in_progress", Op]`, `["migration_in_progress", Campaign]`, `["transaction_id_conflict", Id]`, `["transaction_rejected", Id]`, `["schema_version_mismatch", Expected, Current]`, `["stale_generation", ...]` |
| 413 | Request body too large | `request_too_large` |
| 500 | Unexpected internal failure | `unexpected_result`, or an internal reason |
| 503 | Readiness degraded, catalog not configured, or a temporary overload | `catalog_not_configured`, `read_pool_overloaded`, `["sqlite_error", 5]`, `["sqlite_error", 6]`, `["sqlite_error", 13]` (busy, locked, or full storage); `/v1/ready` returns the health object |
| 504 | Operation timed out | `read_query`, or a write/control timeout reason |

Two cases deserve care:

- **504 on a transaction is ambiguous.** The write may have committed. Retry it
  with the *same* `transaction_id` and identical statements. See
  [Guide: safe retries](#guide-safe-retries).
- **Overloaded reads return 503.** When a replica's read queue is full, the
  request is rejected quickly with `read_pool_overloaded`. Retry with backoff.
- **Reasons with detail are arrays.** The first element names the reason; match on
  it, not on the whole value.

---

## 6. Endpoint reference

### Summary

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/v1/health` | none | Process liveness |
| GET | `/v1/ready` | none | Worker and catalog readiness |
| GET | `/v1/metrics` | admin | Counters, VM pressure, database totals |
| GET | `/v1/databases` | admin | Catalog status and database list |
| POST | `/v1/databases` | admin | Create a database |
| GET | `/v1/databases/{id}` | service (for its database) | Database status |
| DELETE | `/v1/databases/{id}` | admin | Delete a database |
| POST | `/v1/databases/{id}/query` | service (for its database) | Consistent read |
| POST | `/v1/databases/{id}/transactions` | service (for its database) | Replicated write |

### GET /v1/health

Unauthenticated liveness check.

Response `200`:

```json
{"status":"ok"}
```

### GET /v1/ready

Unauthenticated readiness check, suitable for probes. Returns the health object:

```json
{
  "status": "ready",
  "catalog": "ready",
  "missing_workers": []
}
```

- `status` is `ready` or `degraded`. `degraded` returns `503`.
- `catalog` is one of `ready` (3 or more active catalog nodes),
  `under_replicated` (fewer than 3), `unavailable` (catalog query failed), or
  `not_configured`.
- `missing_workers` lists supervised workers that are not running.

Use this endpoint for load-balancer and orchestrator readiness probes.

### GET /v1/metrics

Admin only. Returns:

```json
{
  "status": {"status": "ready", "catalog": "ready", "missing_workers": []},
  "counters": {
    "api_requests_total": 120,
    "api_client_errors_total": 3,
    "api_server_errors_total": 0,
    "database_queries_total": 80,
    "database_query_failures_total": 1,
    "database_writes_total": 40,
    "database_write_failures_total": 0,
    "database_migrations_total": 1,
    "api_request_duration_microseconds": 171428
  },
  "databases": {"count": 12, "active": 9, "cold": 3, "sqlite_bytes": 1048576},
  "vm": {"process_count": 512, "process_limit": 1048576,
         "run_queue": 0, "memory_bytes": 73400320}
}
```

Counters are bounded: names come from code, never from client input, so there is
no per-database label. If the database registry is unavailable, `databases`
is `{"unavailable": true}`.

### GET /v1/databases

Admin only. Returns the catalog status as a `result`. It includes the catalog
nodes and the database records known to the catalog.

### POST /v1/databases

Admin only. Creates a database.

Request:

```json
{"database_id": "merchant-100"}
```

Response `200`: `{"status":"ok"}`.

Errors: `409 database_exists`, `400 invalid_database_id`,
`409 ["database_not_ready", State]` (creation still in progress),
`400 ["missing_field", "database_id"]` when `database_id` is absent.

Creation is durable and idempotent across restarts: the catalog records the
database before physical replicas are created.

### GET /v1/databases/{id}

Service token for that database. Returns the database status as a `result`:

```json
{
  "result": {
    "database_id": "merchant-100",
    "mode": "active",
    "raft_members": 3,
    "schema_version": 1,
    "open_sqlite_replicas": 3,
    "open_sqlite_readers": 3,
    "controller_memory_bytes": 42424,
    "sqlite_owner_memory_bytes": 49496,
    "sqlite_reader_memory_bytes": 98304,
    "raft_server_memory_bytes": 147716,
    "sqlite_bytes": 49152
  }
}
```

- `mode` is `active` (replicas open) or `cold` (replicas closed until the next
  request).
- `schema_version` is the version every transaction must declare (see
  [Transaction statements and values](#8-transaction-statements-and-values)).
  It is `null` if no replica is reachable.
- The byte fields are resource measurements, not guarantees.

Errors: `404 database_not_found`, `403 database_forbidden`. A database that has
been deleted reports `409 ["database_not_ready", "tombstoned"]` rather than 404.

### DELETE /v1/databases/{id}

Admin only. Deletes the database. The catalog fences new operations first;
physical files are removed only after the replica group is safely retired.

Response `200`: `{"status":"ok"}`.

Errors: `404 database_not_found`, `409` (for example
`["movement_in_progress", Op]`) while a movement, repair, migration, or restore
is in progress for the database.

### POST /v1/databases/{id}/query

Service token for that database. Runs a single read-only `SELECT`. The read
is *consistent*: it observes every write acknowledged before the request.

Request:

```json
{
  "sql": "SELECT sku, name FROM products WHERE sku = ?",
  "params": ["ABC1"],
  "timeout_ms": 15000
}
```

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `sql` | yes | — | One `SELECT`. See [Query SQL policy](#7-query-sql-policy). |
| `params` | no | `[]` | Positional parameters: strings, numbers, or `null`. |
| `timeout_ms` | no | `15000` | 1 to 60000. See [Timeouts](#9-timeouts-and-retries). |

Response `200`:

```json
{"result":{"columns":["sku","name"],"rows":[["ABC1","Product"]]}}
```

- `columns` lists column names in order.
- `rows` is an array of arrays, one value per column. Values are JSON strings,
  numbers, or `null`. Do not select raw BLOB columns: their bytes are not
  guaranteed to be valid UTF-8. Select `hex(column)` instead.

Errors:

- `400 unsafe_query` — the SQL is not an allowed read.
- `400 ["missing_field", "sql"]` — `sql` is absent.
- `400 invalid_request` — `params` or `timeout_ms` is malformed.
- `504 read_query` — the deadline passed before the read completed.
- `400 ["sqlite_error", 1]` — SQLite rejected the statement (for example a
  missing table).
- `503` with `["sqlite_error", 5|6|13]` — the database is busy or storage is
  full; retry later.
- `409 ["database_not_ready", State]` — the database is not yet serving.

### POST /v1/databases/{id}/transactions

Service token for that database. Applies a group of statements as one
replicated write. All statements commit atomically or none does.

Request:

```json
{
  "transaction_id": "sale-2026-10-04-0001",
  "schema_version": 1,
  "statements": [
    {"sql": "INSERT INTO products(sku, name) VALUES(?, ?)",
     "params": ["ABC2", "Widget"]},
    {"sql": "UPDATE stock SET qty = qty - ? WHERE sku = ?",
     "params": [1, "ABC2"]}
  ],
  "timeout_ms": 15000
}
```

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `transaction_id` | yes | — | Caller-chosen ID. Use a value unique to the logical operation. |
| `statements` | yes | — | Non-empty array of `{sql, params}` objects. |
| `schema_version` | no | `0` | Must equal the database's current `schema_version` from `GET /v1/databases/{id}`. A mismatch is rejected. |
| `timeout_ms` | no | `15000` | 1 to 60000. |

Response `200`:

```json
{"result": 42}
```

`result` is the committed Raft log index. Keep it if you need to order writes.

Behavior:

- **Idempotent by `transaction_id`.** Re-sending the same ID with identical
  statements after a successful commit returns `200` without applying the
  mutations again. The `result` is the index of that retry's own log entry, so it
  can differ from the first response; the data is written once.
- **Conflicting reuse fails.** Re-sending the same ID with *different*
  statements is rejected with `409 ["transaction_id_conflict", Id]`.
- **Deterministic failures are durable.** A transaction that fails for a
  content-determined reason is recorded under its transaction ID, and the replica
  moves past it. Two such reasons are a `UNIQUE` or other constraint violation, and
  a declared `schema_version` that does not match the database's current version.
  Retrying the same ID returns `409 ["transaction_rejected", Id]`. Use a new ID
  after fixing the cause.

Errors: `400 invalid_request` (malformed statement), `400 ["missing_field", Key]`,
`400 ["unsupported_replicated_sql", Sql]` (DDL or a non-deterministic statement),
`409 ["database_not_ready", State]`, `504` for a timed-out write (ambiguous; see
[safe retries](#guide-safe-retries)).

Schema changes (`CREATE`, `ALTER`, `DROP`) are not accepted by `/transactions`.
They use Erlang's migration interface, which advances `schema_version`. See
[`migrations.md`](migrations.md).

---

## 7. Query SQL policy

`/query` accepts exactly one `SELECT` statement. The policy rejects, with
`400 unsafe_query`:

- anything that is not a `SELECT`
- multiple statements (a semicolon outside a string literal)
- comments (`--`, `/*`, `*/`)
- statements that modify data or schema: `INSERT`, `UPDATE`, `DELETE`,
  `CREATE`, `DROP`, `ALTER`, `REPLACE`, `VACUUM`, `REINDEX`, `ANALYZE`,
  `ATTACH`, `DETACH`, `PRAGMA`
- references to Erlite's internal tables (`__erlite_*`), `sqlite_master`,
  `sqlite_schema`, and `load_extension`

Keywords are matched as whole words, so column names such as `updated_at` or
`created_at` are allowed. String literal contents are ignored by the policy, so
`WHERE note = 'delete from products'` is accepted.

Consistent reads also run with SQLite `query_only` enabled, so SQLite itself
rejects any write that somehow passes the lexical policy.

Allowed:

```sql
SELECT sku, name FROM products WHERE sku = ?
SELECT count(*) AS n FROM orders WHERE created_at >= ?
```

Rejected:

```sql
DELETE FROM products                      -- not a SELECT
SELECT 1; DROP TABLE products             -- multiple statements
SELECT name FROM sqlite_master            -- internal schema
SELECT * FROM __erlite_transactions       -- internal table
```

---

## 8. Transaction statements and values

Statements in `/transactions` pass the deterministic replicated-SQL policy.
Operations whose results can differ between replicas are rejected. Examples:
`random()`, `CURRENT_TIMESTAMP`, `datetime('now')`, unordered row selection that
affects a write, extensions, and `ATTACH`.

Resolve timestamps and generated identifiers in the application and pass them as
parameters:

```json
{"sql": "INSERT INTO orders(id, created_at) VALUES(?, ?)",
 "params": ["ord-7781", "2026-10-04T09:30:00Z"]}
```

Parameter values must be JSON strings, numbers, or `null`. Objects and arrays
are rejected with `400 invalid_request`.

Schema changes are not sent through `/transactions`; they use Erlite's
migration mechanism (see `docs/migrations.md`).

---

## 9. Timeouts and retries

`timeout_ms` is an absolute budget for the whole operation. It covers, in order:
database activation, the leader's quorum barrier, catch-up of the serving
replica, and the SQL itself. Each internal step receives only the time that
remains.

- The caller stops waiting at the deadline and receives `504`.
- Work already in progress inside Erlite may finish after the response; its
  result is discarded.
- A read that is still queued when its deadline passes is dropped before it
  reaches a reader.

When a replica's read pool and queue are full, reads fail fast with
`read_pool_overloaded` (503) rather than waiting.
Back off and retry.

Retry rules:

| Operation | Safe to retry? | How |
| --- | --- | --- |
| Query | Yes | Reads have no side effects. |
| Transaction returned `200` | Not needed | It committed. |
| Transaction returned `504` | Yes, with care | Retry with the **same** `transaction_id` and identical statements. |
| Transaction rejected as `transaction_id_conflict` | No | The ID was used for different content. Use a new ID. |
| Transaction rejected as `transaction_rejected` | No with the same ID | The ID is durably rejected. Fix the cause and use a new ID. |
| Transaction rejected as `schema_version_mismatch` | No with the same ID | Read `schema_version` from status and resend with a new ID. |
| Create database returned `409 database_exists` | Not needed | It exists. |
| Any `5xx` other than `504` | Yes, with backoff | Investigate if it persists. |

---

## 10. Limits

| Limit | Value |
| --- | --- |
| Request body | 1 MiB (`413` above this) |
| Header block | 16 KiB |
| Default operation timeout | 15 seconds |
| Maximum `timeout_ms` | 60 seconds |
| Connections | One request per connection |
| Reader workers per replica | 1 by default, capped at 8 (server configuration) |
| Read queue per replica | 64 waiting requests by default (server configuration) |

---

## Rolling upgrades

The token store needs cluster protocol 2. Upgrade nodes one at a time. Token management is not available until every
active node runs protocol 2 or later, and the enable step checks this:

1. Upgrade every node. Check that each one joins and reports the new release.
2. Run `erlite_api_tokens:enable()`. Each node is asked directly which release it
   runs. It refuses with `{nodes_below_token_store_protocol, Names}` if any active
   node is older, and with `{nodes_unreachable, ...}` if a node cannot be asked.
   A node reports its release to the catalog at every start, so the stored record
   follows an in-place upgrade.
3. After enabling, a node on an older release cannot join: the catalog refuses it
   with `cluster_protocol_too_old_for_token_store`.

Until step 2, static configuration credentials continue to work and tokens cannot
be issued.

## 11. Guides

### Guide: first deployment check

Check a new deployment end to end. The schema of a database is created by the
operator through Erlang's migration interface. The HTTP API cannot create tables,
so this guide assumes the database already has a `products` table.

1. Confirm `GET /v1/health` returns `{"status":"ok"}`.
2. Confirm `GET /v1/ready` returns `200` with `"catalog":"ready"`.
3. Admin token: `POST /v1/databases` for a test ID.
4. Service token scoped to that ID: `GET /v1/databases/{id}` and confirm
   `raft_members` is 3 and read `schema_version`.
5. Service token: write with that `schema_version` and read the rows back.
6. Admin token: delete the test database.

```bash
BASE=https://erlite.example:8443
CA=/etc/erlite/tls/ca.crt

curl -fsS --cacert "$CA" "$BASE/v1/health"
curl -fsS --cacert "$CA" "$BASE/v1/ready"

curl -fsS --cacert "$CA" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_id":"smoke-test"}' "$BASE/v1/databases"

VERSION=$(curl -fsS --cacert "$CA" -H "Authorization: Bearer $SERVICE_TOKEN" \
  "$BASE/v1/databases/smoke-test" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["schema_version"])')

curl -fsS --cacert "$CA" -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"transaction_id\":\"smoke-1\",\"schema_version\":$VERSION,\"statements\":[{\"sql\":\"INSERT INTO products(sku,name) VALUES(?,?)\",\"params\":[\"ABC1\",\"Product\"]}]}" \
  "$BASE/v1/databases/smoke-test/transactions"

curl -fsS --cacert "$CA" -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sql":"SELECT sku, name FROM products"}' "$BASE/v1/databases/smoke-test/query"

curl -fsS --cacert "$CA" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -X DELETE "$BASE/v1/databases/smoke-test"
```

Note: a brand-new database has no tables. Querying one returns
`400 ["sqlite_error", 1]` until a migration creates the schema.

### Guide: safe retries

A `504` from `/transactions` does not tell you whether the write committed.
Retry it with the same `transaction_id` and identical statements:

```python
import json
import time
import urllib.error
import urllib.request
import ssl

BASE_URL = "https://erlite.example:8443"
TOKEN = "replace-with-service-token"
CONTEXT = ssl.create_default_context(cafile="/etc/erlite/tls/ca.crt")


def post(path, payload):
    req = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=CONTEXT, timeout=20) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as err:
        return err.code, json.load(err)


def write_once(database_id, transaction_id, schema_version, statements, attempts=5):
    payload = {"transaction_id": transaction_id,
               "schema_version": schema_version,
               "statements": statements}
    for attempt in range(attempts):
        status, body = post(f"/v1/databases/{database_id}/transactions", payload)
        if status == 200:
            return body["result"]           # committed Raft index
        if status == 504 and attempt + 1 < attempts:
            time.sleep(0.5 * (2 ** attempt))  # same ID, same statements
            continue
        raise RuntimeError(f"transaction {transaction_id} failed: {status} {body}")
    raise RuntimeError("unreachable")


index = write_once(
    "merchant-100",
    "sale-2026-10-04-0002",
    schema_version=1,  # read from GET /v1/databases/{id} -> result.schema_version
    statements=[{"sql": "INSERT INTO products(sku, name) VALUES(?, ?)",
                 "params": ["ABC3", "Gadget"]}],
)
print("committed at Raft index", index)
```

Never generate a new `transaction_id` on a retry of the same logical operation:
that could apply the sale twice.

### Guide: paginated reads

Erlite does not impose a row limit on `SELECT`. Page explicitly in SQL so that
each request stays within `timeout_ms`:

```json
{"sql": "SELECT sku, name FROM products WHERE sku > ? ORDER BY sku LIMIT 100",
 "params": ["ABC1"]}
```

Use the last `sku` from the previous page as the next cursor. Always include an
`ORDER BY` on a unique key; otherwise pages can overlap or skip rows.

### Guide: multi-step writes

A transaction is atomic, but a business operation spanning several databases is
not. Erlite does not provide cross-database transactions. Model the operation
inside one database, or use idempotent steps keyed by a shared business ID:

1. Write the intent to the primary database with `transaction_id = "order-<id>-intent"`.
2. Perform each follow-up write with its own deterministic `transaction_id`.
3. On restart, re-run the steps; the deterministic IDs make re-runs harmless.

### Guide: monitoring

Scrape `GET /v1/metrics` as admin (or use `/v1/ready` for probes). Useful
signals:

- `counters.api_server_errors_total` rising: investigate server logs.
- `counters.database_query_failures_total` rising while `api_client_errors_total`
  is flat: likely timeouts or overload.
- `databases.cold` growing: databases are being cooled; expect slightly slower
  first requests.
- `status.status` other than `ready`: check `missing_workers` and `catalog`.

Do not put database IDs in metric labels; Erlite keeps counters bounded for this
reason.

### Guide: client libraries

Working clients are in [`examples/python/client.py`](../examples/python/client.py)
and [`examples/php/client.php`](../examples/php/client.php). Both verify the
server certificate, send the bearer token, and show a query and a transaction.
Start from them rather than writing TLS handling yourself.

### Guide: token rotation

1. Generate new tokens of at least 32 random bytes.
2. Add the new credential entries alongside the old ones and apply the API
   configuration. New connections accept both.
3. Move clients to the new tokens.
4. Remove the old credential entries and apply again.

Tokens never belong in source control. Store them in your secret manager and
inject them at runtime.
