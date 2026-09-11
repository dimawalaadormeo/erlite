# erlite-deploy: AI operator guide

You are helping someone deploy an Erlite cluster. This file is the complete,
model-agnostic contract for how to do that -- it works the same whether you
are Claude, Codex, Qwen, or anything else, in an agentic coding tool or a
plain chat window. Nothing here is specific to one AI vendor.

## The one hard rule

**Never hand-write deployment scripts, manifests, or config files from
memory.** Your job is to have a conversation, build a JSON config object,
and either run the `erlite-deploy` binary or tell the user the exact command
to run it themselves. The binary is the only thing that actually knows how
to render a docker-compose file, a systemd unit, a Kubernetes manifest, etc.
If you improvise those instead of going through it, your output will
silently drift from what the same config would produce through the GUI or
through the CLI directly -- which defeats the entire point of this tool
having one generator.

## Step 0: figure out which mode you're in

- **Mode 1 (agentic)** -- you can run shell commands (Claude Code, Codex
  CLI, Qwen behind an agent harness with a bash/exec tool, etc.). Go to
  "Mode 1" below.
- **Mode 2 (chat-only)** -- you're in a plain chat interface with no file or
  command execution (e.g. pasted into a web chat box). Go to "Mode 2" below.

If you're not sure, try running `erlite-deploy version`. If that's possible
for you, you're in Mode 1.

## The question flow

Ask questions in this order, skipping any whose `appliesTo` doesn't include
the target once the user has picked one. Do not ask about fields whose
answer you can already tell from context (e.g. don't ask "how many nodes"
if the user already said "three servers"). Apply the listed default when the
user has no preference; do not silently apply a default for anything marked
required, or for anything security-sensitive (`tlsMode`,
`adminCredentialSource`) -- confirm those explicitly even if you'd pick the
default anyway.

If you have shell access, get the authoritative, up-to-date question list by
running:

```
erlite-deploy questions --json
erlite-deploy questions --target docker --json   # filtered to one target
```

Each entry has: `id` (the JSON field this answers), `prompt`, `help`,
`type`, `enum` (for enum types), `default`, `required`, and `appliesTo`. Ask
in the order returned.

If you don't have shell access (Mode 2), use this list, which mirrors the
same source (`internal/config/questions.go`):

1. **target** (required, enum: docker, podman, kubernetes, server,
   proxmox_vm, proxmox_lxc) -- kubernetes and the proxmox targets are
   defined but not yet generatable; say so if the user picks one.
2. **clusterName** (required)
3. **nodes** (required) -- name, host/IP, and which one is the seed, for at
   least 3 nodes. The seed runs `erlite init-cluster`; the rest run
   `erlite join <seed>`.
4. **replicationFactor** (default 3)
5. **storagePath** (default `/var/lib/erlite`)
6. **diskSizeGiB**
7. **diskReserveBytes** (default 1073741824 -- matches Erlite's own
   placement admission gate)
8. **clusterDistPortRange** (default `9100-9105`)
9. **apiPort** (default 4433)
10. **tlsMode** (default `generate-self-signed`, enum: generate-self-signed,
    provide-existing) -- confirm explicitly
11. **tlsCertPath** / **tlsKeyPath** -- only if tlsMode is provide-existing
12. **firewall** (default true)
13. **adminCredentialSource** (default `generate`, enum: generate, prompt,
    external) -- confirm explicitly
14. **otpVersion** (default 26.2)
15. **erliteReleaseRef** (required) -- git tag, release tarball URL, or
    container image tag
16. **sqliteBuildId** (optional)
17. **cpuPerNode** / **memoryPerNode** (optional)
18. **metricsScrapeEnabled** (default false)
19. **logShipping** (default none)
20. *(containers only)* **imageSource** (default build, enum: build, pull),
    **imageRef** (if pull), **registry**
21. *(kubernetes only)* **k8sNamespace** (required), **k8sStorageClass**
22. *(server/proxmox only)* **osFamily** (required), **sshUser** (required),
    **cloudProvider** (server only, default none)
23. *(proxmox only)* **proxmoxApiEndpoint** (required), **proxmoxNode**
    (required), **proxmoxTemplate**, **proxmoxBridge** (default vmbr0),
    **proxmoxStaticIp**, **coresPerNode**, **ramMiBPerNode**
24. **autoBootstrap** (default false) -- see the warning under Mode 1 below
25. **upgradeStrategy** (default rolling)

## Mode 1: agentic (you can run commands)

1. Interview the user following the question flow above.
2. Write the answers to a config file, e.g. `erlite-deploy.config.json`.
3. Validate before generating:
   ```
   erlite-deploy validate --config erlite-deploy.config.json --json
   ```
   This returns `{"valid": bool, "errors": [...]}`. If `valid` is false, fix
   the config from the listed errors and validate again -- don't guess at
   what's wrong, the errors are specific and complete (every problem is
   reported, not just the first).
4. Once valid, generate:
   ```
   erlite-deploy generate --config erlite-deploy.config.json --out ./out --json
   ```
   This returns `{"generated": [...], "outDir": "..."}`. Every generator
   also always produces `DEPLOY_GUIDE.md` in that output -- you don't need
   to write your own summary of what to do next, point the user at it (and
   feel free to read it and summarize it for them).
5. Present the file list to the user. **If `autoBootstrap` was requested,
   do not run `bootstrap-cluster.sh` / `provision-all.sh` without an
   explicit, separate confirmation from the user first** -- those scripts
   provision real infrastructure and bootstrap a real Raft cluster. Generating
   files is safe and reversible; running them against real servers is not.
   Treat it the same as any other hard-to-reverse, infrastructure-affecting
   action: state clearly what it will do, then wait for a yes.

## Mode 2: chat-only (you cannot run commands)

1. Interview the user following the same question flow above.
2. You cannot run `erlite-deploy`, and per the hard rule you must not
   hand-write the scripts either. Instead:
   - Print the finished config as a JSON code block.
   - Tell the user the exact command to run it themselves:
     ```
     erlite-deploy generate --config erlite-deploy.config.json --target <target> --out ./out
     ```
   - Say plainly that this requires the `erlite-deploy` binary on their
     machine, since you have no way to check whether they have it or fetch
     it for them.
3. This is a real, honest limitation of a no-tool-access session -- it
   produces a validated config, not files. That's fine. Don't try to work
   around it by describing what the files "would look like" -- that's the
   same drift risk as hand-writing them.

## What's actually AI-specific

Everything above is identical to what the GUI wizard does with the same
answers. The one thing an AI can add in Mode 1: inspect the *existing*
environment before asking (e.g. check for a `kubectl` context, existing SSH
config entries, or Proxmox API credentials already set) and use that to
pre-fill defaults or skip questions whose answer is already evident. Still
validate the final config against the schema before generating -- an
AI-filled config gets no less scrutiny than a human-filled one.
