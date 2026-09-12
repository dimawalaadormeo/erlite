---
name: erlite-deploy
description: Interactively configure and generate an Erlite cluster deployment (Docker/Podman, server/VM, and eventually Kubernetes/Proxmox) -- scripts, systemd units, TLS, and a tailored install guide. Use when the user wants to deploy or stand up an Erlite cluster.
---

# erlite-deploy

This skill has no logic of its own. Read
`tools/erlite-deploy/ai/AI_GUIDE.md` (relative to the Erlite repo root) in
full and follow it exactly -- it is the model-agnostic contract shared by
every AI front-end to this tool (Claude, Codex, Qwen, or anything else), so
this skill exists only to point you at it, not to duplicate it.

In short: interview the user using the question flow in `AI_GUIDE.md`,
build a config JSON, validate it with `erlite-deploy validate`, generate
with `erlite-deploy generate`, and never hand-write the deployment scripts
yourself. `AI_GUIDE.md` has the full detail on both operating modes
(agentic vs. chat-only) and the confirmation rule around actually running
bootstrap scripts against real infrastructure.
