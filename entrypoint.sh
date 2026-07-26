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
        if (d.systemPrompt) fs.writeFileSync(`${out}/system-prompt.md`, d.systemPrompt);
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
}

apply_snapshot "${BUZZ_AGENT_SNAPSHOT:-}"

export BUZZ_ACP_AGENT_COMMAND="${BUZZ_ACP_AGENT_COMMAND:-claude-agent-acp}"

exec buzz-acp "$@"
