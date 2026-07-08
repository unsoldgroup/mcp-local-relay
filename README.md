# mcp-local-relay

[![npm version](https://img.shields.io/npm/v/@unsoldgroup/mcp-local-relay?logo=npm&color=cb3837)](https://www.npmjs.com/package/@unsoldgroup/mcp-local-relay)
[![npm downloads](https://img.shields.io/npm/dm/@unsoldgroup/mcp-local-relay?logo=npm&color=cb3837)](https://www.npmjs.com/package/@unsoldgroup/mcp-local-relay)
[![GitHub stars](https://img.shields.io/github/stars/unsoldgroup/mcp-local-relay?logo=github)](https://github.com/unsoldgroup/mcp-local-relay/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/unsoldgroup/mcp-local-relay?logo=github)](https://github.com/unsoldgroup/mcp-local-relay/network/members)
[![CI](https://github.com/unsoldgroup/mcp-local-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/unsoldgroup/mcp-local-relay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Node](https://img.shields.io/badge/node-%E2%89%A524-3c873a)

Persistent local MCP relay for developer machines.

`mcp-local-relay` runs once on localhost, connects to remote MCP servers in the background, caches tool discovery, exposes health/status, and lets agents hot-add or refresh upstream MCP servers through MCP tools. It is meant to make clients like Codex, Claude, Cursor, and desktop apps point at one fast local MCP endpoint instead of each paying remote startup/auth/tool-list costs.

> **Status: v0.1 — public initial release.** Streamable HTTP upstreams, cached
> tool discovery, hot-swap MCP onboarding tools, PostHog CLI-mode preset,
> macOS LaunchAgent helpers, JSON health/status endpoints, and a SwiftUI status
> bar app source package are implemented. Start with
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
> [docs/STATUS-BAR.md](docs/STATUS-BAR.md).

## Why

Raw MCP clients often do eager startup discovery. Remote or large MCP servers can slow launch, fail on auth, or inject huge tool schemas into context. A persistent local relay gives you:

- fast localhost startup
- cached `tools/list`
- low-context provider presets, starting with PostHog CLI mode
- LaunchAgent lifecycle and logs on macOS
- `/healthz` and `/status`
- hot-swap onboarding via MCP management tools

## How it works

1. **One local MCP endpoint** — clients connect once to `127.0.0.1`.
2. **Persistent upstreams** — remote MCP servers stay warm outside the client process.
3. **Cached discovery** — `tools/list` is served from a local cache while refreshes happen in the background.
4. **Hot-swap onboarding** — agents use `relay_*` MCP tools to add, validate, refresh, enable, or disable upstream servers.
5. **Observable runtime** — LaunchAgent logs plus `/healthz` and `/status` make failures inspectable.

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

The optional macOS status bar app lives in
`macos/McpLocalRelayStatusBar`. It is a small SwiftUI `MenuBarExtra` app
that reads the local admin API, shows relay/server status, refreshes upstream
tool caches, restarts the LaunchAgent-backed relay, opens the logs folder, and
copies client config without reading env files.

```sh
cd macos/McpLocalRelayStatusBar
swift run
```

To install it as a login item from a checkout:

```sh
pnpm install:status-bar
```

That builds the app into `~/Applications/Mcp Local Relay Status Bar.app`,
registers `~/Library/LaunchAgents/com.unsoldgroup.mcp-local-relay-status-bar.plist`,
and opens it immediately. Remove it with:

```sh
pnpm uninstall:status-bar
```

The local admin API used by the app is:

- `GET /status`
- `GET /client-config`
- `POST /servers/:id/refresh`
- `POST /restart`

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — relay shape, tool naming, and hot-swap flow.
- **[docs/STATUS-BAR.md](docs/STATUS-BAR.md)** — design notes for the optional macOS menu bar monitor.
- **[SECURITY.md](.github/SECURITY.md)** — private disclosure and secret-handling posture.
- **[SUPPORT.md](.github/SUPPORT.md)** — what to include in bug reports.

## About

Built by **[Unsold Group](https://unsold.group)** — a group of innovative travel brands leveraging AI to improve customer experience and operations.

This project came out of production work on **[Expedition Insure](https://expedition.insure)**, Unsold Group's travel insurance platform for polar, expedition, and adventure travel. Expedition Insure uses agent workflows, MCP tools, local context systems, and operational automations every day; `mcp-local-relay` packages one of the infrastructure patterns that made those workflows faster and more reliable.

If you are building with AI agents in a real operational environment, follow:

- **[unsold.group](https://unsold.group)** — innovative travel brands using AI to deliver better customer experiences.
- **[expedition.insure](https://expedition.insure)** — expedition and adventure travel insurance for polar, remote, and hard-to-place trips.

## Feedback & contact

There is no telemetry. We only know what users report.

- **[Discussions](https://github.com/unsoldgroup/mcp-local-relay/discussions)** — questions, ideas, and integration notes.
- **[Issues](https://github.com/unsoldgroup/mcp-local-relay/issues)** — bugs and feature requests.
- Security/privacy issues → **[SECURITY.md](.github/SECURITY.md)**.
- More from the builders → **[unsold.group](https://unsold.group)**.

## License

[MIT](LICENSE)
