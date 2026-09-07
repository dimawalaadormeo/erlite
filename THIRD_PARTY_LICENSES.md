# Third-Party Licenses

Erlite depends on the packages below. Versions are taken from `rebar.lock`.
These packages are not relicensed by Erlite's Apache License 2.0.

For the dual-licensed RabbitMQ packages, Erlite uses them under the Apache
License 2.0 option. Copies of the dependency license texts are included in
their source distributions and must be retained when those sources are
redistributed.

| Package | Version | Relationship | License used by Erlite | Source |
|---|---:|---|---|---|
| [esqlite](https://github.com/mmzeeman/esqlite) | 0.9.0 | Direct | Apache-2.0 | Hex package |
| [ra](https://github.com/rabbitmq/ra) | 3.2.0 | Direct | Apache-2.0 (also offered under MPL-2.0) | Hex package |
| [aten](https://github.com/rabbitmq/aten) | 0.6.0 | Transitive through `ra` | Apache-2.0 (also offered under MPL-2.0) | Hex package |
| [gen_batch_server](https://github.com/rabbitmq/gen-batch-server) | 0.10.0 | Transitive through `ra` | Apache-2.0 (also offered under MPL-2.0) | Hex package |
| [seshat](https://github.com/rabbitmq/seshat) | 1.0.1 | Transitive through `ra` | Apache-2.0 (also offered under MPL-2.0) | Hex package |

The `esqlite` package includes SQLite source code. SQLite is dedicated to the
public domain; its source carries the SQLite blessing in place of a copyright
license. See [SQLite Copyright](https://www.sqlite.org/copyright.html).

This inventory covers the locked Erlang build dependencies as of
2026-09-08. Erlang/OTP, build tools, operating-system libraries, and optional
deployment components are not bundled by this repository and are not listed
here. Re-check this file whenever `rebar.lock` changes.
