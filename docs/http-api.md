# Erlite HTTP API

Phase 6 provides a TLS-only HTTP/1.1 JSON service. The listener is disabled
unless explicitly configured. Requests other than `GET /v1/health` require an
`Authorization: Bearer <token>` header.

## Configuration

Configure the `erlite_core` application before it starts:

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
               databases => [<<"merchant-100">>] }]}}
```

Tokens shorter than 32 bytes or malformed credential records never
authenticate. An admin identity can use control and data operations. A service
identity can use data operations only for its configured database allow-list;
`databases => all` grants access to every database but still grants no control
operations. Replacing the API configuration rotates credentials for new
connections.

## Endpoints

- `GET /v1/health` — unauthenticated process health.
- `GET /v1/databases` — admin catalog status and database list.
- `POST /v1/databases` — admin create with `{"database_id":"..."}`.
- `GET /v1/databases/{id}` — authorized database status.
- `DELETE /v1/databases/{id}` — admin delete.
- `POST /v1/databases/{id}/query` — authorized consistent read with
  `{"sql":"SELECT ...","params":[],"timeout_ms":15000}`.
- `POST /v1/databases/{id}/transactions` — authorized replicated transaction
  with `transaction_id`, optional `schema_version`, `statements`, and optional
  `timeout_ms`.

Database IDs in paths use standard percent encoding. Request bodies are capped
at 1 MiB, headers at 16 KiB, and operation timeouts at 60 seconds. Connections
are closed after one response. Query SQL must be a single `SELECT`, cannot
contain comments or additional statements, and cannot address Erlite's internal
tables. Consistent reads additionally run with SQLite `query_only` enabled, so
the engine rejects mutations even if the lexical policy were to miss one.
Transaction statements pass through the deterministic replicated-SQL
policy and all values must be JSON strings, numbers, or `null`.

Successful calls return `{"status":"ok"}` or `{"result":...}`. Errors return
`{"error":...}` with an appropriate 4xx/5xx status. A timed-out transaction has
an ambiguous commit outcome; retry it with the same `transaction_id` and
identical statements.

Malformed request lines, headers, and content lengths return `400`. Negative or
non-numeric content lengths, duplicate headers, and unsupported transfer
encodings are rejected before authentication or dispatch.

The bearer token protects application access, while TLS protects it in transit.
Deploy certificates from the operator's trusted PKI, restrict listener access at
the network layer, keep token material outside source control, and use encrypted
storage for Erlite data and backups.
