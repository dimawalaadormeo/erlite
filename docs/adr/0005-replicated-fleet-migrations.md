# ADR 0005: Replicated fleet migrations

Status: accepted

## Context

Schema changes must be ordered with writes for each independently replicated
SQLite database. Fleet rollout state must survive process and leader failure.

## Decision

Represent each schema step as a database Raft command with immutable set and
migration IDs, a content hash, consecutive versions, and ordered DDL. Apply the
DDL, history, schema version, and Raft index in one SQLite transaction. Store
campaigns and attempt state in the catalog Raft group. Complete deterministic
canaries before bounded batches and durably pause on canary failure.
Campaign IDs are deterministically derived from a caller-supplied idempotency
key and set name. A per-database catalog fence serializes every migration step
against movement, repair, restore, and deletion. Pause state remains sticky
when results that were already in flight arrive.

## Consequences

The database Raft log remains the schema ordering authority. Catalog progress
cannot make incomplete SQLite work successful. Application, module, and
database-specific packs share one mechanism. The initial DDL subset excludes
data migrations and nondeterministic SQLite features.
