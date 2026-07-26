#!/bin/bash
set -euo pipefail

# Auth comes from CLAUDE_CODE_OAUTH_TOKEN, minted on a machine with a browser:
#
#   claude setup-token
#
# That is the supported path for a headless subscription login — no copying of
# ~/.claude onto the server, no SSH-forwarded OAuth callback.
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ERROR: no Claude credentials." >&2
    echo "Set CLAUDE_CODE_OAUTH_TOKEN (from 'claude setup-token') or ANTHROPIC_API_KEY." >&2
    exit 1
fi

# Fail fast and loudly rather than looping on a bad token.
if ! claude auth status >/dev/null 2>&1; then
    echo "WARNING: 'claude auth status' did not report an authenticated session." >&2
    echo "Continuing anyway — the adapter may still authenticate via the token." >&2
fi

# Register HTTP MCP servers on every boot. ~/.claude.json lives in the container
# filesystem, not a volume, so it is lost whenever the container is recreated;
# rebuilding it here keeps the config declarative and the token out of the image.
#
# buzz-acp cannot carry these itself — its McpServer struct is stdio-only
# (name/command/args/env, no url or type) and it passes at most one server, so
# HTTP MCPs have to be configured on the Claude side instead.
register_http_mcp() {
    local name="$1" url="$2" token="$3"
    [[ -z "$name" || -z "$url" || -z "$token" ]] && return 0
    # Accept a bare token as well as a full header value.
    [[ "$token" != *" "* ]] && token="Bearer ${token}"
    if claude mcp add --transport http "$name" "$url" \
            --header "Authorization: ${token}" >/dev/null 2>&1; then
        echo "registered MCP server: ${name} -> ${url}"
    else
        echo "WARNING: failed to register MCP server ${name}" >&2
    fi
}

# Indexed MCP slots, so one image serves agents with different toolsets and no
# MCP is special-cased by name here:
#   MCP1_NAME=executor MCP1_URL=https://... MCP1_TOKEN=...
#   MCP2_NAME=other    MCP2_URL=https://... MCP2_TOKEN=...
for i in 1 2 3 4 5; do
    n="MCP${i}_NAME"; u="MCP${i}_URL"; t="MCP${i}_TOKEN"
    register_http_mcp "${!n:-}" "${!u:-}" "${!t:-}"
done

# stdio MCP servers. The spawned process inherits this container's environment,
# so credentials are plain env vars rather than per-server --env flags.
register_stdio_mcp() {
    local name="$1" cmd="$2"
    [[ -z "$name" || -z "$cmd" ]] && return 0
    # shellcheck disable=SC2086 — cmd is a command plus args, split intentionally.
    if claude mcp add "$name" -- $cmd >/dev/null 2>&1; then
        echo "registered MCP server (stdio): ${name} -> ${cmd}"
    else
        echo "WARNING: failed to register stdio MCP server ${name}" >&2
    fi
}

for i in 1 2 3; do
    n="MCPS${i}_NAME"; c="MCPS${i}_CMD"
    register_stdio_mcp "${!n:-}" "${!c:-}"
done

# Agent snapshot — Buzz's own portable agent definition (`.agent.json`, the
# format Buzz Desktop exports and imports). buzz-acp does not read it, so this
# translates the parts that map onto its flags.
#
# Keeping the persona here rather than in an environment variable means it is
# reviewable in git, and the same file can be imported by Buzz Desktop or
# published to a registry. Explicit environment always wins, so a resource can
# override any single field without editing the snapshot.
apply_snapshot() {
    local file="$1"
    [[ -z "$file" ]] && return 0
    if [[ ! -r "$file" ]]; then
        echo "ERROR: BUZZ_AGENT_SNAPSHOT=$file is not readable." >&2
        exit 1
    fi

    local dir
    dir="$(mktemp -d)"

    # node is in the base image, so parsing JSON costs no extra dependency.
    # The prompt goes to a file rather than a variable: it is multi-line, and
    # BUZZ_ACP_SYSTEM_PROMPT_FILE exists precisely for this.
    if ! node -e '
        const fs = require("fs");
        const [src, out] = process.argv.slice(1);
        const s = JSON.parse(fs.readFileSync(src, "utf8"));
        if (s.format !== "buzz-agent-snapshot") {
            throw new Error(`not an agent snapshot: format=${JSON.stringify(s.format)}`);
        }
        if (s.version !== 1) {
            throw new Error(`unsupported snapshot version ${s.version}`);
        }
        const d = s.definition || {};
        const p = s.profile || {};
        if (d.systemPrompt) fs.writeFileSync(`${out}/system-prompt.md`, d.systemPrompt);
        // Profile fields go to their own file: they are published with the
        // buzz CLI, not passed to buzz-acp.
        fs.writeFileSync(`${out}/profile.json`, JSON.stringify({
            name: p.displayName || d.name || null,
            about: p.about || null,
            avatar: p.avatarUrl || null,
            nip05: p.nip05 || null,
        }));
        const kv = [];
        if (d.model) kv.push(`model=${d.model}`);
        if (d.respondTo) kv.push(`respond_to=${d.respondTo}`);
        if (d.parallelism) kv.push(`parallelism=${d.parallelism}`);
        if (Array.isArray(d.respondToAllowlist) && d.respondToAllowlist.length) {
            kv.push(`allowlist=${d.respondToAllowlist.join(",")}`);
        }
        if (d.idleTimeoutSeconds) kv.push(`idle_timeout=${d.idleTimeoutSeconds}`);
        if (d.maxTurnDurationSeconds) kv.push(`max_turn=${d.maxTurnDurationSeconds}`);
        fs.writeFileSync(`${out}/vars`, kv.join("\n") + "\n");
        console.log(`snapshot: ${d.name || "unnamed"}${d.systemPrompt ? " (with system prompt)" : ""}`);
    ' "$file" "$dir"; then
        echo "ERROR: could not apply snapshot $file" >&2
        exit 1
    fi

    if [[ -f "$dir/system-prompt.md" ]]; then
        export BUZZ_ACP_SYSTEM_PROMPT_FILE="${BUZZ_ACP_SYSTEM_PROMPT_FILE:-$dir/system-prompt.md}"
    fi

    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        case "$k" in
            model)        export BUZZ_ACP_MODEL="${BUZZ_ACP_MODEL:-$v}" ;;
            respond_to)   export BUZZ_ACP_RESPOND_TO="${BUZZ_ACP_RESPOND_TO:-$v}" ;;
            parallelism)  export BUZZ_ACP_AGENTS="${BUZZ_ACP_AGENTS:-$v}" ;;
            allowlist)    export BUZZ_ACP_RESPOND_TO_ALLOWLIST="${BUZZ_ACP_RESPOND_TO_ALLOWLIST:-$v}" ;;
            idle_timeout) export BUZZ_ACP_IDLE_TIMEOUT="${BUZZ_ACP_IDLE_TIMEOUT:-$v}" ;;
            max_turn)     export BUZZ_ACP_MAX_TURN_DURATION="${BUZZ_ACP_MAX_TURN_DURATION:-$v}" ;;
        esac
    done < "$dir/vars"

    SNAPSHOT_PROFILE="$dir/profile.json"
}

# Publish the snapshot's profile as this identity's kind:0.
#
# Nothing else will: buzz-acp only ever *reads* kind:0 (to identify authors and
# check NIP-OA tags), and Nostr profiles are self-asserted — a relay can accept
# or reject the write but cannot assign a name. So an agent with a fresh key
# appears nameless until it publishes for itself.
#
# kind:0 is replaceable, so this is idempotent and runs every boot: editing the
# snapshot and redeploying is how you rename an agent. Never fatal — a relay
# with BUZZ_REQUIRE_RELAY_MEMBERSHIP will 403 this until the agent is added as
# a member, and being nameless is no reason to refuse to start.
publish_profile() {
    local file="${1:-}"
    [[ -z "$file" || ! -r "$file" ]] && return 0
    [[ "${BUZZ_AGENT_PUBLISH_PROFILE:-true}" != "true" ]] && return 0

    # NUL-separated via a file, so an `about` containing spaces arrives as a
    # single argument instead of being re-split by the shell.
    local argfile="${file}.args"
    if ! node -e '
        const fs = require("fs");
        const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (!p.name) process.exit(2);
        const out = [];
        for (const [flag, key] of [["--name","name"],["--about","about"],["--avatar","avatar"],["--nip05","nip05"]]) {
            if (p[key]) out.push(flag, p[key]);
        }
        // Trailing NUL too: `read -d ""` needs each field terminated, not
        // merely separated, or it drops the last one.
        fs.writeFileSync(process.argv[2], out.map((x) => x + "\0").join(""));
    ' "$file" "$argfile"; then
        return 0   # exit 2 — no name in the snapshot, nothing to publish
    fi

    local -a argv=()
    while IFS= read -r -d "" a; do argv+=("$a"); done < "$argfile"

    if buzz users set-profile "${argv[@]}" >/dev/null 2>&1; then
        echo "published profile: ${argv[1]}"
    else
        echo "WARNING: could not publish profile (relay membership required?)" >&2
    fi
}

# First-boot introduction.
#
# A headless agent with a generated key is a stranger to the community. It has
# no way in on its own: BUZZ_ACP_CHANNELS only filters what it subscribes to —
# it cannot create the kind:39002 membership that makes a channel visible — and
# there is no desktop session to attach it to one. So on first boot it joins
# whatever channels it was told about and opens a DM to its owner, which always
# works and leaves somewhere to talk.
#
# Once only, guarded by a marker on the work volume. Not because `buzz dms
# open` would create duplicate threads — the relay dedupes on a participant-set
# hash and hands back the existing channel (buzz-db/src/dm.rs:377) — but
# because that same call *unhides* the DM, and re-greeting the owner on every
# restart would be obnoxious.
bootstrap() {
    local marker="/var/lib/buzz/work/.bootstrap-done"
    [[ "${BUZZ_AGENT_BOOTSTRAP:-true}" != "true" ]] && return 0
    [[ -f "$marker" ]] && return 0
    [[ -z "${BUZZ_ACP_AGENT_OWNER:-}" ]] && return 0

    # Via a local with a default: bash 5 treats ${UNSET//,/ } as an unbound
    # variable under `set -u` and aborts, where bash 3.2 quietly yields empty.
    local channels="${BUZZ_ACP_CHANNELS:-}" ch
    for ch in ${channels//,/ }; do
        [[ -z "$ch" ]] && continue
        if buzz channels join --channel "$ch" >/dev/null 2>&1; then
            echo "joined channel ${ch}"
        else
            echo "WARNING: could not join channel ${ch} (invite-only, or not a member yet)" >&2
        fi
    done

    local out dm
    if ! out=$(buzz dms open --pubkey "$BUZZ_ACP_AGENT_OWNER" 2>/dev/null); then
        echo "WARNING: could not open owner DM — will retry next boot" >&2
        return 0
    fi
    dm=$(node -e '
        const v = JSON.parse(process.argv[1]);
        if (!v.dm_id) process.exit(1);
        process.stdout.write(v.dm_id);
    ' "$out" 2>/dev/null) || { echo "WARNING: no dm_id in response — will retry next boot" >&2; return 0; }

    local hello="${BUZZ_AGENT_HELLO:-}"
    if [[ -z "$hello" && -r "${SNAPSHOT_PROFILE:-/nonexistent}" ]]; then
        hello=$(node -e '
            const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
            process.stdout.write(`${p.name || "This agent"} is online.` + (p.about ? ` ${p.about}` : ""));
        ' "$SNAPSHOT_PROFILE" 2>/dev/null) || hello=""
    fi

    if [[ -n "$hello" ]] && buzz messages send --channel "$dm" --content "$hello" >/dev/null 2>&1; then
        echo "opened owner DM ${dm} and said hello"
    else
        echo "opened owner DM ${dm}"
    fi

    # Only mark done once the DM exists, so a relay that was not ready yet
    # gets another attempt rather than the agent silently never introducing itself.
    touch "$marker" 2>/dev/null || true
}

# A URL wins over a path: it is how you change a persona without rebuilding.
snapshot_path="${BUZZ_AGENT_SNAPSHOT:-}"
if [[ -n "${BUZZ_AGENT_SNAPSHOT_URL:-}" ]]; then
    snapshot_path=/tmp/agent-snapshot.json
    if ! curl -fsSL --max-time 20 "$BUZZ_AGENT_SNAPSHOT_URL" -o "$snapshot_path"; then
        echo "ERROR: could not fetch BUZZ_AGENT_SNAPSHOT_URL=${BUZZ_AGENT_SNAPSHOT_URL}" >&2
        exit 1
    fi
    echo "fetched snapshot from ${BUZZ_AGENT_SNAPSHOT_URL}"
fi

apply_snapshot "$snapshot_path"
publish_profile "${SNAPSHOT_PROFILE:-}"
bootstrap

export BUZZ_ACP_AGENT_COMMAND="${BUZZ_ACP_AGENT_COMMAND:-claude-agent-acp}"

exec buzz-acp "$@"
