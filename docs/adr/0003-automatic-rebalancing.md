# ADR 0003: Automatic rebalancing uses catalog-fenced movement

- Status: accepted
- Date: 2026-09-08

## Context

New nodes do not receive existing databases automatically. Rebalancing must
spread independent database replicas without creating another membership
protocol or overlapping repair and movement for one database.

## Decision

The catalog leader owns automatic planning. The initial load metric is the
number of ready replicas on each healthy active node. A move is eligible only
when its source has at least two more replicas than an eligible target that does
not already host that database. Databases with repair or movement work are
excluded.

Planning is deterministic and bounded by
`rebalance_max_migrations_per_scan`. Selected migrations form a sequential
in-memory queue. Projected counts are updated after every selection, and a
database is selected at most once per scan. Every item is executed through the
durable Phase 7 movement workflow. A later scan always replans from consistent
catalog state, so the queue itself requires no durable duplicate state.

## Consequences

- Replacement catch-up and verification still precede source removal.
- Catalog generation and operation-ID fences serialize rebalance with repair.
- Worker or leader failure loses only an unsubmitted plan; durable movements
  remain recoverable through lifecycle reconciliation.
- Replica count does not model disk, traffic, leader count, or failure domains;
  those weights remain future extensions driven by measurements.
