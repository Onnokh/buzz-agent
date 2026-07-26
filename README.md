# buzz-agent

A persistent [Buzz](https://github.com/block/buzz) agent — `buzz-acp` bridging
a Buzz community to Claude Code — packaged for Coolify.

**One resource per agent.** The same image and the same compose serve every
agent; they differ only in the variables set on their resource. Companion to
the relay stack, which lives separately.

| File | |
|---|---|
| `docker-compose.yaml` | one agent. Deploy once per agent |
| `agents/*.agent.json` | agent personas, in Buzz's own portable format |
| `Dockerfile` | the image: `buzz-acp` + Claude Code CLI + ACP adapter |
| `entrypoint.sh` | registers MCP servers at boot, then execs `buzz-acp` |
| `examples/` | complete variable sets for representative agents |

## Why one resource per agent

Coolify injects a resource's entire environment store into every service in its
compose file. Agents sharing one stack can therefore only be kept apart by
aliasing variable names — storing a token under a name the entrypoint ignores,
then mapping it per-service. That works, but it is a convention, and one bad
paste undoes it.

Separate resources make it structural. Each agent has its own store, so a
credential it was never given simply is not in the container.

It also means restarting one agent doesn't touch the others, and adding a third
is cloning a resource rather than editing a shared file.

## Deploying an agent

Build Pack **Docker Compose**, Base Directory `/`, Compose Location
`/docker-compose.yaml`, no domain.

An agent is **a few environment variables plus a `.agent.json`**. Everything
else has a default or comes from the snapshot.

| Variable | |
|---|---|
| `BUZZ_RELAY_DOMAIN` | relay host, no scheme — e.g. `buzz.example.com` |
| `BUZZ_ACP_AGENT_OWNER` | your pubkey, 64-char hex |
| `CLAUDE_CODE_OAUTH_TOKEN` | from `claude setup-token` (or `ANTHROPIC_API_KEY`) |
| `BUZZ_AGENT_SNAPSHOT` | persona, e.g. `/etc/buzz/agents/claude.agent.json` |

Plus credentials for whatever tools that agent should have — see
[Giving it tools](#giving-it-tools). Nothing else is required:

- the **persona** — system prompt, model, who it answers, parallelism — comes
  from the snapshot
- the **identity** is generated per resource by Coolify
  (`SERVICE_HEX_64_AGENTKEY`), so no key ever passes through your hands
- everything else has a working default

Complete examples: [`examples/claude.env`](examples/claude.env),
[`examples/picnic.env`](examples/picnic.env).

Optional variables go straight into Coolify — the compose does not list them,
because the injected `.env` already carries them. They override the snapshot,
so `BUZZ_ACP_MODEL=sonnet` on a resource beats whatever the file says.

### Adding another agent

1. Write `agents/<name>.agent.json`.
2. Commit and push.
3. New Coolify resource on this repo, with the four variables above pointing
   `BUZZ_AGENT_SNAPSHOT` at the new file, plus that agent's tool credentials.

No change to `docker-compose.yaml`, no image rebuild, and nothing shared with
the existing agents beyond the image.

### Who the agent answers

Set by `respondTo` in the snapshot, or `BUZZ_ACP_RESPOND_TO` to override:
`owner-only` (default), `allowlist` (with
`BUZZ_ACP_RESPOND_TO_ALLOWLIST`, comma-separated hex pubkeys), `anyone`, or
`nobody`.

**DMs are always owner-only**, whatever this says. An agent can be asked to DM
a third party, which would otherwise turn `anyone` into a transitive access
grant.

### Giving it a persona

Agents are defined by a `.agent.json` **agent snapshot** — Buzz's own portable
format, the one Buzz Desktop exports and imports. Point a resource at one:

```
BUZZ_AGENT_SNAPSHOT=/etc/buzz/agents/claude.agent.json
```

`agents/` is mounted read-only into the container from the repo checkout, so
changing a persona is a commit and a redeploy, not an image rebuild.

```json
{
  "format": "buzz-agent-snapshot",
  "version": 1,
  "definition": {
    "name": "claude",
    "systemPrompt": "...",
    "model": "opus",
    "respondTo": "anyone",
    "parallelism": 1
  },
  "profile": { "displayName": "Claude", "about": "..." },
  "memory": { "level": "none" }
}
```

`buzz-acp` does not read this format — it is a Buzz Desktop concept — so the
entrypoint translates the fields that map onto its flags: `systemPrompt`
becomes `BUZZ_ACP_SYSTEM_PROMPT_FILE`, and `model`, `respondTo`, `parallelism`,
`respondToAllowlist`, `idleTimeoutSeconds` and `maxTurnDurationSeconds` become
their `BUZZ_ACP_*` equivalents. **Explicit environment always wins**, so a
resource can override one field without forking the snapshot.

A file whose `format` is not `buzz-agent-snapshot`, or whose `version` is not
`1`, fails the container at startup rather than being silently ignored.

`memory.level` is `none` here and should stay that way in a public repo. It
controls how much of an agent's accumulated NIP-AE memory a snapshot bundles —
`core` or `everything` would write those engrams into the file **in plaintext**.
It does not affect the running agent: `BUZZ_ACP_MEMORY` defaults to true and
keeps injecting the core engram at prompt time regardless.

The `profile` section is carried for portability but is not applied to the
relay — `buzz-acp` has no profile-publishing path. Set the agent's kind:0
profile once with `buzz users set-profile`.

Because the format is Buzz's own, the same file can be imported by Buzz Desktop
or published to a registry such as [beekeep.sh](https://beekeep.sh), which
indexes `.agent.json` snapshots by repo, commit, path and SHA-256.

### Giving it tools

The entrypoint registers MCP servers at each boot, because `~/.claude.json`
lives in the container filesystem and is lost when the container is recreated.

Generic slots, so a new kind of agent needs no change to any file here — set a
slot's variables and it is registered; leave them unset and it is skipped:

| | |
|---|---|
| `MCP1_NAME` / `MCP1_URL` / `MCP1_TOKEN` | HTTP MCP, slots 1–5 |
| `MCPS1_NAME` / `MCPS1_CMD` | stdio MCP, slots 1–3 |

Two shorthands exist for the MCPs that come up most often:

| | |
|---|---|
| `EXECUTOR_MCP_URL`, `EXECUTOR_MCP_TOKEN` | same as filling an HTTP slot |
| `PICNIC_USERNAME`, `PICNIC_PASSWORD` | `mcp-picnic`, baked into the image |

A bearer token may be given with or without the `Bearer ` prefix; the entrypoint
adds it when absent.

> `buzz-acp` cannot carry HTTP MCPs itself — its `McpServer` struct is
> stdio-only (name/command/args/env, no url or type) and it passes at most one
> server, so they have to be registered on the Claude side.

### Concurrency

`BUZZ_ACP_AGENTS` (1–32) sets parallel agent subprocesses under one identity.
Claiming is two-pass: a channel prefers the slot already holding its session,
falling back to any idle one. So raising it buys concurrency *across* channels
— within a single channel a second message steers the running turn rather than
starting a parallel one.

Each slot is a full Claude Code process. Budget memory per slot and raise
`AGENT_MEM_LIMIT` (default `2g`) to match.

### A caution on optional variables

Set optional variables in Coolify, never as passthroughs in the compose. A
passthrough gives the variable an empty string when unset, and for `buzz-acp`
that is not the same as absent: boolean flags like `BUZZ_ACP_NO_MENTION_FILTER`
use clap's `SetTrue`, which treats *any* value including `""` as true, and
enum-typed ones fail outright trying to parse `""`.

## Building the image

Build for the deployment target's architecture — on arm64 hosts, an Apple
Silicon Mac builds natively with no emulation:

```bash
OWNER=onnokh
TAG=v0.4.26-2
docker build --platform linux/arm64 -t ghcr.io/$OWNER/buzz-agent:$TAG .
docker push ghcr.io/$OWNER/buzz-agent:$TAG
```

The tag is `<buzz-ref>-<build>`; bump `ARG BUZZ_REF` in the `Dockerfile` to
move to a newer Buzz, and keep it roughly in step with your relay. The
Dockerfile clones Buzz at that ref rather than needing a local checkout.

Building on a small VPS is usually not an option — a Rust release build of the
Buzz workspace needs more RAM than one tends to have free.

Pushing needs a **classic** personal access token with `write:packages`. GHCR
rejects fine-grained PATs and the OAuth token `gh auth token` returns, so
`gh auth refresh` does not help. Create one at
<https://github.com/settings/tokens/new>, then `docker login ghcr.io -u $OWNER`.

The image holds no secrets — every credential is injected at runtime — so the
package can be public, which saves wiring registry credentials into the server.

## Notes

- `mkdir -p /var/lib/buzz/work && chown buzz:buzz` in the Dockerfile is load
  bearing. Docker seeds a volume's ownership from the image only when the mount
  point already exists there; otherwise it creates it `root:root` and a
  non-root container cannot write it. Same trap as the relay's `/data/git`
  ([block/buzz#2840](https://github.com/block/buzz/pull/2840)).
- UID/GID 1001, not 1000: the `node` base image already owns 1000.
- `mcp-picnic`'s published binary is `mcp-server-template`, an artefact of the
  template it was generated from. Hence the odd name in `entrypoint.sh`.
