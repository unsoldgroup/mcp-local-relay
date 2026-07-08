# mcp-local-relay

Persistent local MCP relay for developer machines.

`mcp-local-relay` runs once on localhost, connects to remote MCP servers in the background, caches tool discovery, exposes health/status, and lets agents hot-add or refresh upstream MCP servers through MCP tools. It is meant to make clients like Codex, Claude, Cursor, and desktop apps point at one fast local MCP endpoint instead of each paying remote startup/auth/tool-list costs.

## Why

Raw MCP clients often do eager startup discovery. Remote or large MCP servers can slow launch, fail on auth, or inject huge tool schemas into context. A persistent local relay gives you:

- fast localhost startup
- cached `tools/list`
- low-context provider presets, starting with PostHog CLI mode
- LaunchAgent lifecycle and logs on macOS
- `/healthz` and `/status`
- hot-swap onboarding via MCP management tools

## Install

```sh
pnpm add -g @unsoldgroup/mcp-local-relay
mcp-local-relayctl init
mcp-local-relayctl install
mcp-local-relayctl start
```

For development from a checkout:

```sh
pnpm install
pnpm build
node bin/mcp-local-relay.mjs serve --config examples/config.posthog.json
```

## Client Config

Point clients at the relay once:

```json
{
  "mcpServers": {
    "mcp-local-relay": {
      "type": "http",
      "url": "http://127.0.0.1:3764/mcp"
    }
  }
}
```

After that, use the relay's MCP tools to add or update upstream servers without editing the client config.

## Hot-Swap Tools

The relay exposes management tools:

- `relay_list_servers`
- `relay_add_server`
- `relay_update_server`
- `relay_remove_server`
- `relay_enable_server`
- `relay_disable_server`
- `relay_refresh_tools`
- `relay_get_status`
- `relay_get_client_config`
- `relay_validate_server`

When a server is added, updated, removed, enabled, disabled, or refreshed, the relay emits `notifications/tools/list_changed`. Clients that honor the notification can see new tools without a session restart.

## PostHog Preset

Use `mode: "posthog-cli"` to request PostHog's slim CLI MCP surface. Store the API token in an env file:

```sh
mkdir -p ~/.config/mcp-local-relay
umask 077
printf 'POSTHOG_MCP_API_TOKEN=phx_...\n' > ~/.config/mcp-local-relay/posthog.env
```

The token is read at runtime and is not written into client config or LaunchAgent plists.

## LaunchAgent vs stdio

Stdio MCP is simple, but each client process pays startup, auth, and discovery costs. A LaunchAgent relay persists outside the client, keeps logs, warms caches, and can be inspected independently.

## Status

```sh
mcp-local-relayctl status
mcp-local-relayctl logs
curl http://127.0.0.1:3764/status
```

The optional macOS status bar app is planned as a small SwiftUI app that reads `/status`.
