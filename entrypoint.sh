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

# Indexed MCP slots, so one image serves agents with different toolsets:
#   MCP1_NAME=executor MCP1_URL=https://... MCP1_TOKEN=...
#   MCP2_NAME=other    MCP2_URL=https://... MCP2_TOKEN=...
for i in 1 2 3 4 5; do
    n="MCP${i}_NAME"; u="MCP${i}_URL"; t="MCP${i}_TOKEN"
    register_http_mcp "${!n:-}" "${!u:-}" "${!t:-}"
done

# Backwards-compatible with the original single-server variables. No default
# URL — the host is compose's business, and a baked-in one silently goes stale
# when the executor moves.
register_http_mcp executor \
    "${EXECUTOR_MCP_URL:-}" \
    "${EXECUTOR_MCP_TOKEN:-}"

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

# Convenience: mcp-picnic is installed in the image, so setting the Picnic
# credentials is enough to enable it. Its published bin is `mcp-server-template`
# (an artefact of the template it was generated from), hence the odd name.
if [[ -n "${PICNIC_USERNAME:-}" ]]; then
    register_stdio_mcp picnic "mcp-server-template"
fi

export BUZZ_ACP_AGENT_COMMAND="${BUZZ_ACP_AGENT_COMMAND:-claude-agent-acp}"

exec buzz-acp "$@"
