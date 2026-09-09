# ADR 0006: Resource-aware placement and leader balancing

## Status

Accepted

## Decision

Use one deterministic placement policy for database creation and periodic
rebalancing. Rank eligible nodes by replica count, estimated database size,
disk utilization, load, and an optional placement group. `spread` penalizes an
existing group footprint; `pack` prefers it. A database still places at most
one replica on a node. Free space minus the estimated incoming size must remain
above the configured reserve.

Placement inputs are operational hints. Unknown metrics are neutral so an
observation outage does not halt count-based placement, but a supplied invalid
or insufficient disk observation fails closed for that node.

Balance leaders separately and with the same per-scan bound. Discover the
current leader from `ra`, choose only an existing voter on a less loaded node,
and use `ra:transfer_leadership/3`. Do not encode leaders in catalog placement.

## Consequences

All physical replica changes continue through the Phase 7 durable movement
protocol. Scheduling can improve without creating another correctness path.
Leadership remains Raft state and is rediscovered after failure. Operators can
update metrics and group policy without rewriting replicated database records;
deterministic database-specific configuration must therefore be deployed
consistently on nodes eligible to control placement.
