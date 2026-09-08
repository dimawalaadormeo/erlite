# ADR 0004: Fenced backup, restore, and clone

## Status

Accepted

## Context

A SQLite file records the Raft index it has applied. Attaching a backup image
to an unrelated or newer live Raft log can skip commands or replay commands
against the wrong history. Replace restore must also survive a coordinator
crash after the catalog changes but before physical replicas are rebuilt.

## Decision

Backups are immutable SQLite snapshots taken after a quorum barrier and source
catch-up. Their manifest binds database identity, placement generation,
committed/applied Raft index and term, schema and SQLite runtime versions,
creation time, image name, and SHA-256 checksum. Publication succeeds only
after the image reopens and its internal applied index and checksum verify.

Restore has two explicit modes. `replace` advances an existing database's
placement generation and the catalog requires the backup's embedded database
identity to equal that target. `clone` is the only mode allowed to restore into
a different database identity and creates it at generation one.
Both first commit an operation-ID-fenced `restoring` catalog record with a new
three-member placement. Incomplete records are reconciled after restart.

A verified source image is never attached to the target Raft log. Erlite copies
it while offline, atomically resets the applied index to zero and clears the
source transaction ledger while preserving user data, and only then starts a
new Ra group. The catalog publishes `ready` only after all three materialized
replicas and the new group exist. Portable export is a versioned, compressed
Erlang external-term bundle containing the manifest and image bytes and checks
the embedded image checksum when read.

## Consequences

Replace restore intentionally discards writes after the selected backup. Clone
and replace always receive a new Raft history and generation-specific server
IDs. The backup source must remain reachable until the artifact is exported or
the restoring operation completes; failure leaves `restoring` visible and
retryable rather than publishing partial data.
