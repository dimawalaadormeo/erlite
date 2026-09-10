# Phase 13 hardening

This is the executable acceptance map for Phase 13. The invariant across every
case is that Raft remains authoritative, and a SQLite applied index advances
only with the durable materialization of that committed outcome.

The admission and failure semantics are accepted in
`docs/adr/0007-hardening-admission-and-failure-semantics.md`.

| Failure | Expected behavior | Executable evidence |
| --- | --- | --- |
| Network/member partition | A quorum continues; a minority refuses consistent reads and writes; restored members catch up. | `erlite_raft_phase3_SUITE` |
| Repeated leader/member failure | Leadership is rediscovered, writes continue with quorum, and returning replicas converge. | `erlite_raft_phase3_SUITE`, `erlite_cluster_three_node_SUITE` |
| Random core-process crash | Supervisors restart workers and catalog-fenced lifecycle or movement work reconciles. | `erlite_database_SUITE`, `erlite_phase7_SUITE` |
| Delayed SQLite apply | Commit alone is not success; catch-up applies through the barrier before reply/readiness. | `erlite_raft_phase3_SUITE`, `erlite_raft_applier_tests` |
| Damaged or missing replica | A checksummed snapshot is installed and verified before membership replacement; stale copies are quarantined and cleaned. | `erlite_phase7_SUITE`, `erlite_phase8_SUITE` |
| Disk full | SQLite work rolls back and the applied index remains unchanged. | `disk_full_does_not_advance_applied_index_test` |
| Rolling upgrade | Join rejects protocol gaps, durable-format differences, and SQLite runtime differences before persistent membership work. | `erlite_release_tests`, `erlite_cluster_three_node_SUITE` |
| Transaction failure | Deterministic constraint/SQL rejection becomes a durable failed no-op, and later Raft entries continue applying. Resource and I/O failures remain unapplied. | `erlite_sqlite_schema_tests`, `erlite_raft_phase3_SUITE` |
| Migration failure | Deterministic DDL failure becomes a durable failed no-op, leaves schema version unchanged, and pauses a failed canary. Resource failures remain unapplied. | `erlite_database_SUITE`, `erlite_sqlite_schema_tests` |
| Catalog failure | Consistent operations require catalog quorum; durable state survives server/process restart. | `erlite_catalog_SUITE`, `erlite_cluster_three_node_SUITE`, `erlite_database_SUITE` |
| Backup corruption | Checksum/runtime/identity mismatch rejects install, clone, restore, and export input before activation. | `erlite_raft_phase1_SUITE`, `erlite_phase7_SUITE` |
| Observability | Liveness is independent of quorum; readiness checks workers and consistent catalog state; metrics have bounded keys; malformed bodies are counted. | `erlite_observability_tests`, `erlite_api_tests`, `erlite_database_SUITE` |

## Operator response

- Treat a transaction timeout as ambiguous and retry identical content with the
  same transaction ID.
- Do not route new traffic to a node whose `/v1/ready` response is `503`.
- Restore disk capacity before retrying work after an I/O or resource failure.
- Inspect and correct a paused migration campaign before resuming it.
- Never force an incompatible node through the join fence. Format changes need
  an explicit upgrade procedure, which protocol version 1 does not provide.
- Preserve corrupt replicas or backup artifacts for diagnosis; use verified
  replacement/restore workflows rather than editing Erlite metadata manually.
